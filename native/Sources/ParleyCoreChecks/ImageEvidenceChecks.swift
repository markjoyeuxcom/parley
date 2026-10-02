import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ParleyCore
import UniformTypeIdentifiers

// Image evidence in context packs and returned results (Prax 25819d21, MR A):
// an agent stages a PNG or JPEG, Parley checks it is one, keeps its own copy
// and tells the receiving pane how to fetch it.

private func imageExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "ImageEvidence", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func imageRejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw NSError(domain: "ImageEvidence", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
}

/// A real image of the given size, encoded by ImageIO: one colour, or opaque
/// noise, which does not compress, when the size on disk matters.
func imageEvidenceFixture(width: Int, height: Int, type: UTType = .png, noise: Bool = false) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if noise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
        for index in 0..<(context.bytesPerRow * height) { pixels[index] = index % 4 == 3 ? 255 : UInt8.random(in: 0...255) }
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@MainActor let imageEvidenceChecks: [(String, () throws -> Void)] = [
    ("image evidence: the inspector accepts real PNG and JPEG and refuses anything else", {
        let png = imageEvidenceFixture(width: 3, height: 2)
        let image = try ContextImageInspector.inspect(png)
        try imageExpect(image.format == .png && image.width == 3 && image.height == 2 && image.byteCount == png.count && image.sha256 == sha256(png),
                        "a PNG was described wrongly: \(image)")
        let jpeg = imageEvidenceFixture(width: 5, height: 4, type: .jpeg)
        try imageExpect(try ContextImageInspector.inspect(jpeg).format == .jpeg, "a JPEG was not recognised")
        try imageExpect(ContextImageInspector.looksLikeImage(png) && ContextImageInspector.looksLikeImage(jpeg)
                        && !ContextImageInspector.looksLikeImage(Data("# a report\n".utf8)), "the image sniff was wrong")
        try imageRejects("text was accepted as an image") { _ = try ContextImageInspector.inspect(Data("not an image".utf8)) }
        var corrupt = png.prefix(16); corrupt.append(Data(repeating: 0x41, count: 64))
        try imageRejects("a corrupt PNG was accepted") { _ = try ContextImageInspector.inspect(Data(corrupt)) }
        try imageRejects("a GIF was accepted") { _ = try ContextImageInspector.inspect(imageEvidenceFixture(width: 2, height: 2, type: .gif)) }
        try imageRejects("an image over the byte limit was accepted") { _ = try ContextImageInspector.inspect(png, maximumBytes: png.count - 1) }
        let wide = imageEvidenceFixture(width: ContextImageInspector.maximumDimension + 1, height: 1)
        try imageRejects("an image wider than the limit was accepted") { _ = try ContextImageInspector.inspect(wide) }
    }),
    ("image evidence: the store keeps one owner-only copy per digest and checks it on read", {
        let root = URL(fileURLWithPath: "/private/tmp/parley-image-store-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ContextImageStore(directory: root.appendingPathComponent("context-images"))
        let png = imageEvidenceFixture(width: 4, height: 4)
        let image = try store.store(png)
        let again = try store.store(png)
        try imageExpect(image == again, "storing the same bytes twice changed the record")
        let file = store.url(for: image)
        try imageExpect(file.lastPathComponent == "\(image.sha256).png", "the copy is not named by its digest: \(file.lastPathComponent)")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let folder = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        try imageExpect((attributes[.posixPermissions] as? Int) == 0o600 && (folder[.posixPermissions] as? Int) == 0o700,
                        "the copy or its folder is not owner-only")
        try imageExpect(try store.data(for: image) == png, "the stored bytes differ")
        // A copy changed on disk is refused rather than served.
        var tampered = png; tampered[tampered.count - 1] ^= 0xff
        try tampered.write(to: file)
        try imageRejects("a tampered copy was served") { _ = try store.data(for: image) }
        // A link planted where the copy goes is never followed.
        try FileManager.default.removeItem(at: file)
        let elsewhere = root.appendingPathComponent("elsewhere.png")
        try png.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        try imageRejects("a linked copy was served") { _ = try store.data(for: image) }
        try FileManager.default.removeItem(at: file)
        _ = try store.store(png)
        let other = try store.store(imageEvidenceFixture(width: 2, height: 3))
        try imageExpect(store.removeAll(except: [image.sha256]) == 1, "the unreferenced copy was not the one removed")
        try imageExpect(FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: store.url(for: other).path),
                        "the referenced copy went, or the unreferenced one stayed")
        // The store as a whole is bounded: a new copy that would pass the
        // total is refused, while bytes already kept can be staged again.
        let small = ContextImageStore(directory: root.appendingPathComponent("bounded"), maximumTotalBytes: png.count + 10)
        _ = try small.store(png)
        _ = try small.store(png)
        do {
            _ = try small.store(imageEvidenceFixture(width: 9, height: 9))
            throw NSError(domain: "ImageEvidence", code: 4, userInfo: [NSLocalizedDescriptionKey: "a copy past the store's total was kept"])
        } catch ContextImageError.storeFull {}
    }),
    ("image evidence: an image part keeps its image, renders how to fetch it and cannot be edited", {
        let png = imageEvidenceFixture(width: 6, height: 2)
        let image = try ContextImageInspector.inspect(png)
        let part = ContextPackPart.agentImage(image, label: "shot.png", detail: "/w/shot.png · provided by Codex; not independently read by Parley")
        try imageExpect(part.source.kind == .agentFileDraft && part.image == image && part.typeLabel == "Agent-provided image",
                        "the image part lost its kind, image or label")
        try imageExpect(part.text.contains("parley image \(image.sha256) --to"), "the part does not say how to fetch the image: \(part.text)")
        try imageExpect(part.replacingText("ignore the image") == part, "an image part's text was edited")
        let decoded = try JSONDecoder().decode(ContextPackPart.self, from: JSONEncoder().encode(part))
        try imageExpect(decoded == part, "an image part did not survive encoding")
        // A part written before images existed decodes with none.
        let text = ContextPackPart(source: ContextPackSource(kind: .agentFileDraft, label: "r.md", detail: "/w/r.md"), capturedText: "report")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(text)) as! [String: Any]
        json.removeValue(forKey: "image")
        try imageExpect(try JSONDecoder().decode(ContextPackPart.self, from: JSONSerialization.data(withJSONObject: json)).image == nil,
                        "an old part decoded with an image")
        let rendered = try ContextPackBuilder().render(ContextPack(name: "Evidence", parts: [part], origin: .agentProposed))
        for line in ["Type: Agent-provided image", "Image: PNG, 6 × 2 pixels, \(png.count) bytes", "Image SHA-256: \(image.sha256)"] {
            try imageExpect(rendered.contains(line), "the rendered pack lacks \"\(line)\": \(rendered)")
        }
    }),
]

private final class ImageBrokerFixture: @unchecked Sendable {
    let directory: URL
    let credentials: RelayCredentials
    let images: ContextImageStore
    let broker: RelayBroker
    let sourceToken: String
    let targetToken: String
    let otherToken: String

    init(withImages: Bool = true, maximumImageBytes: Int = ContextImageStore.defaultMaximumTotalBytes) throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("image-broker-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        credentials = try RelayCredentials(file: directory.appendingPathComponent("tokens.json"))
        sourceToken = try credentials.token(for: "source")
        targetToken = try credentials.token(for: "target")
        otherToken = try credentials.token(for: "other")
        images = ContextImageStore(directory: directory.appendingPathComponent("context-images"), maximumTotalBytes: maximumImageBytes)
        let folder = directory.path
        let panes = [
            WorkbenchPane(id: "source", kind: .codex, customName: "Driver", terminalTitle: "", cwd: folder, currentCommand: "codex", isActive: true, workspaceID: "w", relayEnabled: true, workspaceName: "Project", automationPolicy: .askAndDelegate),
            WorkbenchPane(id: "target", kind: .claude, customName: "Reviewer", terminalTitle: "", cwd: folder, currentCommand: "claude", isActive: false, workspaceID: "w", relayEnabled: true, workspaceName: "Project", automationPolicy: .askAndDelegate),
            WorkbenchPane(id: "other", kind: .copilot, customName: "Bystander", terminalTitle: "", cwd: folder, currentCommand: "copilot", isActive: false, workspaceID: "w", relayEnabled: true, workspaceName: "Project", automationPolicy: .askAndDelegate),
        ]
        broker = RelayBroker(credentials: credentials, panes: { panes }, paste: { _, _ in }, submit: { _, _ in },
            consultationTimeout: 3, handoffJournal: try RelayHandoffJournal(file: directory.appendingPathComponent("handoffs.jsonl")),
            contextReviewStore: try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json")),
            contextImageStore: withImages ? images : nil)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

    func review(from response: RelayTextResponse) throws -> AgentContextReview {
        let summary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(response.text.utf8))
        return broker.contextReviews().first { $0.id == summary.id }!
    }
}

@MainActor let imageEvidenceBrokerChecks: [(String, () throws -> Void)] = [
    ("image evidence: an agent stages images through context draft, add and done --file", {
        let f = try ImageBrokerFixture()
        let png = imageEvidenceFixture(width: 8, height: 6)
        let drafted = f.broker.handleContextDraft(token: f.sourceToken, name: "Shots", path: f.path("shot.png"), content: .image(png))
        try imageExpect(drafted.status == 201, "an image draft was refused: \(drafted.text)")
        var review = try f.review(from: drafted)
        try imageExpect(review.pack.parts.first?.image != nil, "the draft holds no image")
        let staged = review.pack.parts[0].image!
        try imageExpect(staged.sha256 == sha256(png) && (try f.images.data(for: staged)) == png, "Parley did not keep the staged bytes")
        try imageExpect(review.pack.parts[0].source.detail.contains("checked by Parley"), "the part does not say what Parley checked: \(review.pack.parts[0].source.detail)")
        let jpeg = imageEvidenceFixture(width: 3, height: 3, type: .jpeg)
        let added = f.broker.handleContextAdd(token: f.sourceToken, draftID: review.id, path: f.path("b.jpg"), content: .image(jpeg))
        try imageExpect(added.status == 200, "adding an image was refused: \(added.text)")
        review = f.broker.contextReviews().first { $0.id == review.id }!
        try imageExpect(review.pack.parts.count == 2 && review.pack.parts[1].image?.format == .jpeg, "the added image is missing")
        // Text still stages as text; a non-image is refused as an image.
        try imageExpect(f.broker.handleContextAdd(token: f.sourceToken, draftID: review.id, path: f.path("n.md"), content: .text("notes\n")).status == 200,
                        "text no longer stages")
        try imageExpect(f.broker.handleContextAdd(token: f.sourceToken, draftID: review.id, path: f.path("x.png"), content: .image(Data([0, 1, 2, 3]))).status == 400,
                        "bytes that are not an image were staged")
        let huge = f.broker.handleContextDraft(token: f.sourceToken, name: "Big", path: f.path("big.png"),
                                               content: .image(png + Data(repeating: 0, count: ContextImageInspector.maximumBytes)))
        try imageExpect(huge.status == 413, "an oversized image was not refused as too large: \(huge.status) \(huge.text)")
        // A full store refuses with what the person can do about it.
        let full = try ImageBrokerFixture(maximumImageBytes: png.count + 10)
        try imageExpect(full.broker.handleContextDraft(token: full.sourceToken, name: "A", path: full.path("a.png"), content: .image(png)).status == 201,
                        "the first image did not fit an empty store")
        let refused = full.broker.handleContextDraft(token: full.sourceToken, name: "B", path: full.path("b.png"),
                                                     content: .image(imageEvidenceFixture(width: 9, height: 9)))
        try imageExpect(refused.status == 507 && refused.text.contains("Delete Saved Context"),
                        "a full image store was not refused with its remedy: \(refused.status) \(refused.text)")
        // A returned image waits for review; Parley's receipt adds no digest of its own.
        let delegated = f.broker.handleDelegate(token: f.targetToken, target: "Driver", text: "Capture the window")
        try imageExpect(delegated.status == 200, "could not delegate: \(delegated.body)")
        let returned = f.broker.handleDelegationFileResult(token: f.sourceToken, handoffID: "current", path: f.path("result.png"), content: .image(png))
        try imageExpect(returned.status == 200, "a returned image was refused: \(returned.text)")
        let result = f.broker.contextReviews().first { $0.returnedPart != nil }!
        let receipt = f.broker.handoffs().first { $0.resultContextReviewID == result.id }?.resultText ?? ""
        try imageExpect(result.returnedPart?.image?.sha256 == staged.sha256 && receipt.contains("PNG image") && !receipt.contains(staged.sha256),
                        "the returned image or its receipt is wrong: \(receipt)")
        // Without an image store, an image is refused and text still works.
        let bare = try ImageBrokerFixture(withImages: false)
        try imageExpect(bare.broker.handleContextDraft(token: bare.sourceToken, name: "S", path: bare.path("s.png"), content: .image(png)).status == 503,
                        "an image was staged with no store")
        try imageExpect(bare.broker.handleContextDraft(token: bare.sourceToken, name: "T", path: bare.path("t.md"), content: .text("t\n")).status == 201,
                        "text needed an image store")
    }),
    ("image evidence: only the staging pane or a pane the person sent the image to may fetch it", {
        let f = try ImageBrokerFixture()
        let png = imageEvidenceFixture(width: 5, height: 5)
        let drafted = f.broker.handleContextDraft(token: f.sourceToken, name: "Shots", path: f.path("shot.png"), content: .image(png))
        let review = try f.review(from: drafted)
        let image = review.pack.parts[0].image!
        let digest = image.sha256
        let own = f.broker.handleImageFetch(token: f.sourceToken, digest: digest)
        try imageExpect(own.status == 200 && own.body == png, "the staging pane could not fetch its image: \(own.status)")
        try imageExpect(f.broker.handleImageFetch(token: f.targetToken, digest: digest).status == 403, "a pane never sent the image fetched it")
        try imageExpect(f.broker.handleImageFetch(token: f.sourceToken, digest: "../etc").status == 400, "a malformed digest was accepted")
        // Naming the digest grants nothing: an agent relaying the rendered
        // pack itself, or a returned file named by its digest, whose receipt
        // then names it (Codex's review of MR !138, M1).
        let relayed = f.broker.handle(token: f.sourceToken, target: "Reviewer", text: try ContextPackBuilder().render(review.pack))
        try imageExpect(relayed.status == 200, "the pack could not be relayed: \(relayed.body)")
        try imageExpect(f.broker.handleImageFetch(token: f.targetToken, digest: digest).status == 403,
                        "a pane fetched an image an agent named in a message, which no person reviewed")
        let delegated = f.broker.handleDelegate(token: f.targetToken, target: "Driver", text: "Capture the window")
        try imageExpect(delegated.status == 200, "could not delegate: \(delegated.body)")
        let returned = f.broker.handleDelegationFileResult(token: f.sourceToken, handoffID: "current", path: f.path("\(digest).png"), content: .image(png))
        let receipt = f.broker.handoffs().first { $0.resultContextReviewID != nil }?.resultText ?? ""
        try imageExpect(returned.status == 200 && receipt.contains(digest), "the digest-named file was not returned, or its receipt lacks the name: \(returned.status) \(receipt)")
        try imageExpect(f.broker.handleImageFetch(token: f.targetToken, digest: digest).status == 403,
                        "the lead fetched a returned image before the person sent it")
        // The person sends the draft to the reviewer: now the reviewer may
        // fetch it and a bystander still may not. Nobody answers the Ask, which
        // times out after three seconds; the person's send stands.
        let current = f.broker.contextReviews().first { $0.id == review.id }!
        _ = f.broker.completeContextDraft(AgentContextReviewApproval(reviewID: current.id, expectedUpdatedAt: current.updatedAt,
                                                                     targetPaneID: "target", pack: current.pack))
        let sent = f.broker.contextReviews().first { $0.id == review.id }!
        try imageExpect(sent.state == .completed && sent.requestedTargetPaneID == "target", "the person's send did not complete: \(sent.state)")
        let fetched = f.broker.handleImageFetch(token: f.targetToken, digest: digest)
        try imageExpect(fetched.status == 200 && fetched.body == png, "the pane the person sent the image to could not fetch it: \(fetched.status)")
        try imageExpect(f.broker.handleImageFetch(token: f.otherToken, digest: digest).status == 403, "a bystander fetched the image")
        // Deleting every review that holds it deletes Parley's copy at once.
        let held = f.broker.contextReviews().filter { ($0.pack.parts + [$0.returnedPart].compactMap { $0 }).contains { $0.image?.sha256 == digest } }
        let deleted = f.broker.deleteContextReviews(AgentContextDeletion(reviews: held.map {
            AgentContextDraftDiscard(reviewID: $0.id, expectedUpdatedAt: $0.updatedAt)
        }))
        try imageExpect(deleted.status == 200, "could not delete the reviews: \(deleted.text)")
        try imageExpect(f.broker.handleImageFetch(token: f.targetToken, digest: digest).status == 404
                        && !FileManager.default.fileExists(atPath: f.images.url(for: image).path),
                        "an image outlived its reviews, on disk or to a fetch")
    }),
    ("image evidence: a copy goes once no review holds it or is being saved with it, and a full store makes room first", {
        // Saving a review can prune an older one, and the collection that
        // follows runs before the new review joins the broker's map. The copy
        // it holds is pinned from before it is written until then (Codex's
        // review of MR !138, M5), not protected by its age.
        let f = try ImageBrokerFixture()
        for index in 0..<100 {
            let drafted = f.broker.handleContextDraft(token: f.sourceToken, name: "N\(index)", path: f.path("n.md"), content: .text("note \(index)\n"))
            let review = try f.review(from: drafted)
            let discarded = f.broker.discardContextDraft(AgentContextDraftDiscard(reviewID: review.id, expectedUpdatedAt: review.updatedAt))
            try imageExpect(discarded.status == 200, "could not discard filler review \(index): \(discarded.text)")
        }
        let png = imageEvidenceFixture(width: 7, height: 7)
        let drafted = f.broker.handleContextDraft(token: f.sourceToken, name: "Shot", path: f.path("shot.png"), content: .image(png))
        try imageExpect(drafted.status == 201 && f.broker.contextReviews().count == 100, "the image draft was not saved over a pruned review: \(drafted.status)")
        let image = try f.review(from: drafted).pack.parts[0].image!
        try imageExpect(FileManager.default.fileExists(atPath: f.images.url(for: image).path)
                        && f.broker.handleImageFetch(token: f.sourceToken, digest: image.sha256).status == 200,
                        "the collection that pruning ran removed the copy its own review was being saved with")
        // A copy no review holds, such as one left by a crash, makes way for a
        // new one when the store is full, whether staging holds the broker
        // lock (done --file) or not (context draft).
        let orphan = imageEvidenceFixture(width: 30, height: 30)
        let incoming = imageEvidenceFixture(width: 31, height: 31)
        let cap = max(orphan.count, incoming.count) + 10
        for useDelegation in [false, true] {
            let full = try ImageBrokerFixture(maximumImageBytes: cap)
            let left = try full.images.store(orphan)
            let staged: Int
            if useDelegation {
                _ = full.broker.handleDelegate(token: full.targetToken, target: "Driver", text: "Capture the window")
                staged = full.broker.handleDelegationFileResult(token: full.sourceToken, handoffID: "current", path: full.path("r.png"), content: .image(incoming)).status
            } else {
                staged = full.broker.handleContextDraft(token: full.sourceToken, name: "New", path: full.path("new.png"), content: .image(incoming)).status
            }
            try imageExpect((staged == 200 || staged == 201) && !FileManager.default.fileExists(atPath: full.images.url(for: left).path),
                            "a full store did not make room from a copy no review holds (done --file: \(useDelegation)): \(staged)")
        }
    }),
    ("image evidence: an image goes through the shim and transport and back with parley image", { try checkImageEvidenceThroughTheShim() }),
]

/// The whole path a real agent uses: the shim cats the file into the request,
/// the transport keeps its bytes, the broker stages it, and `parley image`
/// writes the bytes back where the agent asks.
func checkImageEvidenceThroughTheShim() throws {
    let f = try ImageBrokerFixture()
    let transportDirectory = f.directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shim = try RelayShim.install(in: f.directory, transportDirectory: transportDirectory).appendingPathComponent("parley").path
    let transport = RelayFileTransport(broker: f.broker, credentials: f.credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer {
        f.broker.cancelAll()
        transport.stop()
    }
    let runner = ProcessCommandRunner(timeout: 10)
    func parley(_ token: String, _ arguments: [String]) throws -> CommandOutput {
        try runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [shim] + arguments,
                       environment: ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": token]) { _, supplied in supplied },
                       input: nil)
    }
    let png = imageEvidenceFixture(width: 640, height: 400)
    let shot = f.directory.appendingPathComponent("shot.png")
    try png.write(to: shot)
    let drafted = try parley(f.sourceToken, ["context", "draft", "--name", "Shots", "--file", shot.path])
    try imageExpect(drafted.status == 0, "the shim could not stage an image: \(drafted.stdoutText) \(drafted.stderrText)")
    let summary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(drafted.stdoutText.utf8))
    let review = f.broker.contextReviews().first { $0.id == summary.id }!
    let digest = try imageExpectValue(review.pack.parts.first?.image?.sha256, "the staged draft holds no image")
    let notes = f.directory.appendingPathComponent("notes.md")
    try "# Notes\n".write(to: notes, atomically: true, encoding: .utf8)
    let added = try parley(f.sourceToken, ["context", "add", review.id, "--file", notes.path])
    try imageExpect(added.status == 0, "text no longer stages through the shim: \(added.stderrText)")
    let out = f.directory.appendingPathComponent("fetched.png")
    let fetched = try parley(f.sourceToken, ["image", digest, "--to", out.path])
    try imageExpect(fetched.status == 0 && (try Data(contentsOf: out)) == png, "the fetched image differs: \(fetched.stderrText)")
    let refused = f.directory.appendingPathComponent("refused.png")
    let other = try parley(f.otherToken, ["image", digest, "--to", refused.path])
    try imageExpect(other.status != 0 && other.stderrText.contains("did not stage that image") && !FileManager.default.fileExists(atPath: refused.path),
                    "a pane never sent the image fetched it, or a refusal left a file: \(other.status) \(other.stderrText)")
    // A refusal leaves a file already at the destination as it was, and no
    // partial reply beside it.
    let existing = f.directory.appendingPathComponent("existing.png")
    try Data("keep me".utf8).write(to: existing)
    let kept = try parley(f.otherToken, ["image", digest, "--to", existing.path])
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.directory.path).filter { $0.contains(".parley-") }
    try imageExpect(kept.status != 0 && (try Data(contentsOf: existing)) == Data("keep me".utf8) && leftovers.isEmpty,
                    "a refused fetch changed the file already there or left a partial reply: \(kept.status) \(leftovers)")
    // A reply that cannot be written out in full is a failure, never a saved
    // image: a file-size limit stops the copy of this one partway, and the
    // copy over the destination would then fit (Codex's review of MR !138,
    // M2).
    let noisy = imageEvidenceFixture(width: 64, height: 64, noise: true)
    let noisyFile = f.directory.appendingPathComponent("noisy.png")
    try noisy.write(to: noisyFile)
    let noisyDraft = try parley(f.sourceToken, ["context", "draft", "--name", "Noise", "--file", noisyFile.path])
    let noisySummary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(noisyDraft.stdoutText.utf8))
    let noisyDigest = try imageExpectValue(f.broker.contextReviews().first { $0.id == noisySummary.id }?.pack.parts.first?.image?.sha256,
                                           "the noisy draft holds no image")
    let limited = try runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "ulimit -f 4; exec /bin/sh \"$0\" \"$@\"", shim, "image", noisyDigest, "--to", existing.path],
                                 environment: ProcessInfo.processInfo.environment.merging(["PARLEY_RELAY_TOKEN": f.sourceToken]) { _, supplied in supplied },
                                 input: nil)
    let limitedLeftovers = try FileManager.default.contentsOfDirectory(atPath: f.directory.path).filter { $0.contains(".parley-") }
    try imageExpect(noisy.count > 8_192 && limited.status != 0 && (try Data(contentsOf: existing)) == Data("keep me".utf8) && limitedLeftovers.isEmpty,
                    "a reply cut short was saved as the image: \(noisy.count) bytes, \(limited.status) \(limited.stderrText) \(limitedLeftovers)")
    let malformed = try parley(f.sourceToken, ["image", "abc", "--to", out.path])
    try imageExpect(malformed.status == 2, "a malformed digest reached the broker: \(malformed.status)")
    // A file over either bound names both, for an image and for text alike.
    let oversized = f.directory.appendingPathComponent("huge.png")
    var bytes = png
    bytes.append(Data(count: ContextImageInspector.maximumBytes + 1 - png.count))
    try bytes.write(to: oversized)
    let longText = f.directory.appendingPathComponent("long.md")
    try String(repeating: "x", count: 200_001).write(to: longText, atomically: true, encoding: .utf8)
    for file in [oversized, longText] {
        let refused = try parley(f.sourceToken, ["context", "draft", "--name", "Big", "--file", file.path])
        let said = refused.stdoutText + refused.stderrText
        try imageExpect(refused.status != 0 && said.contains("image of at most \(ContextImageInspector.maximumBytes) bytes")
                        && said.contains("nothing was staged"),
                        "\(file.lastPathComponent) over the bound was not refused with both limits: \(refused.status) \(said)")
    }
    // Four staging requests so far, refusals included, each holding one of the
    // transport's four staging slots while it ran: had one not been given
    // back, these would wait past the runner's timeout.
    for _ in 0..<2 {
        let more = try parley(f.sourceToken, ["context", "add", review.id, "--file", shot.path])
        try imageExpect(more.status == 0, "a staging slot was not given back: \(more.status) \(more.stdoutText) \(more.stderrText)")
    }
}

private func imageExpectValue<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw NSError(domain: "ImageEvidence", code: 3, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
}
