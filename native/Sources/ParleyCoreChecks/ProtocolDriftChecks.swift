import CryptoKit
import Foundation
import ParleyCore

/// The protocol text and its version stamp move together: a pane whose stamp
/// is behind shows RESTART FOR PROTOCOL, and that only works when every
/// wording change bumps the version. This pins a digest of the text beside
/// the version, so a change that forgets the bump fails here rather than in
/// a pane that learned different words under the same number.
func checkProtocolTextMatchesItsVersion() throws {
    let digest = SHA256.hash(data: Data(AgentProtocol.text.utf8)).map { String(format: "%02x", $0) }.joined()
    let pinned = (version: "35", digest: "da5449020da111c789ea57085e860af18a22ede52778139288ae9ebd7144c2c1")
    guard AgentProtocol.version == pinned.version, digest == pinned.digest else {
        throw NSError(domain: "ProtocolDrift", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "AgentProtocol.text or AgentProtocol.version changed (version \(AgentProtocol.version), text digest \(digest)). "
            + "If the wording changed, bump AgentProtocol.version; then pin the new version and digest in ProtocolDriftChecks.swift."])
    }
}

@MainActor
let protocolDriftChecks: [(String, () throws -> Void)] = [
    ("the protocol text matches its version stamp", checkProtocolTextMatchesItsVersion),
]
