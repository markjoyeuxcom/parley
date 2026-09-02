import Foundation

public struct AutomaticUpdateConfiguration: Equatable, Sendable {
    public static let expectedFeedURL = URL(
        string: "https://github.com/markjoyeuxcom/parley/releases/latest/download/appcast.xml"
    )!

    public let feedURL: URL
    public let publicKey: String
    public let checksEnabledByDefault: Bool
    public let downloadsEnabledByDefault: Bool

    public static func resolve(
        runtime: ParleyRuntime,
        infoDictionary: [String: Any]
    ) -> AutomaticUpdateConfiguration? {
        guard runtime.mode == .production,
              let feed = infoDictionary["SUFeedURL"] as? String,
              let feedURL = URL(string: feed),
              feedURL == expectedFeedURL,
              let publicKey = infoDictionary["SUPublicEDKey"] as? String,
              let publicKeyBytes = Data(base64Encoded: publicKey),
              publicKeyBytes.count == 32,
              publicKeyBytes.base64EncodedString() == publicKey,
              (infoDictionary["SURequireSignedFeed"] as? Bool) == true,
              (infoDictionary["SUVerifyUpdateBeforeExtraction"] as? Bool) == true,
              (infoDictionary["SUAllowsAutomaticUpdates"] as? Bool) == false,
              (infoDictionary["SUEnableSystemProfiling"] as? Bool) == false,
              let checksEnabled = infoDictionary["SUEnableAutomaticChecks"] as? Bool,
              let downloadsEnabled = infoDictionary["SUAutomaticallyUpdate"] as? Bool,
              checksEnabled == false,
              downloadsEnabled == false else {
            return nil
        }
        return AutomaticUpdateConfiguration(
            feedURL: feedURL,
            publicKey: publicKey,
            checksEnabledByDefault: checksEnabled,
            downloadsEnabledByDefault: downloadsEnabled
        )
    }
}
