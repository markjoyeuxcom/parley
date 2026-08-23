import Foundation
import ServiceManagement

enum CoreLoginItemState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }
}

@MainActor
final class CoreLoginItemController {
    static let plistName = "com.markjoyeux.parley.core.plist"

    private var service: SMAppService {
        SMAppService.agent(plistName: Self.plistName)
    }

    var state: CoreLoginItemState {
        switch service.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    func register() throws {
        guard state != .unavailable else {
            throw CoreLoginItemError.unavailable
        }
        guard !state.isRegistered else { return }
        try service.register()
    }

    func unregister() async throws {
        guard state.isRegistered else { return }
        let service = service
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

private enum CoreLoginItemError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Launch at login is available from the packaged Parley.app, which contains the signed core LaunchAgent."
    }
}
