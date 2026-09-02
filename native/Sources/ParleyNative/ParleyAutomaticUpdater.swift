import Foundation
import ParleyCore
import Sparkle

@MainActor
final class ParleyAutomaticUpdater {
    let configuration: AutomaticUpdateConfiguration
    private let controller: SPUStandardUpdaterController
    private(set) var isStarted = false

    init?(runtime: ParleyRuntime, bundle: Bundle = .main) {
        guard let configuration = AutomaticUpdateConfiguration.resolve(
            runtime: runtime,
            infoDictionary: bundle.infoDictionary ?? [:]
        ) else {
            return nil
        }
        self.configuration = configuration
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        isStarted && controller.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        controller.updater.automaticallyChecksForUpdates
    }

    func start() {
        guard !isStarted else { return }
        controller.startUpdater()
        isStarted = true
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isStarted else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
