import AppKit
import ImageIO
import ParleyCore
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The person's own window capture for a context pack, and the only code in
/// Parley that captures the screen. The system window picker is where the
/// person chooses the window, so Parley never lists windows, reads their
/// titles or captures anything they did not pick; one picked window gives one
/// still image and the picker is switched off again. No agent route reaches
/// this: it runs only from the Capture Window button of the person's own pack.
@MainActor
enum WindowCapture {
    struct Captured {
        let data: Data
        let width: Int
        let height: Int
    }

    enum Failure: LocalizedError {
        case unavailable(String)
        case tooLarge(width: Int, height: Int)

        var errorDescription: String? {
            switch self {
            case let .unavailable(detail):
                "Parley could not capture that window: \(detail)"
            case let .tooLarge(width, height):
                "The window (\(width) × \(height) pixels) is too large to send as one image of at most \(ContextImageInspector.maximumBytes) bytes. Make it smaller and capture it again."
            }
        }
    }

    /// Shows the system window picker and captures the window the person
    /// picks. Nil when they cancel.
    static func pickAndCapture() async throws -> Captured? {
        let picker = SCContentSharingPicker.shared
        let observer = PickerObserver()
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleWindow
        picker.defaultConfiguration = configuration
        picker.add(observer)
        picker.isActive = true
        // A picker that never answers would hold every add-source button
        // in the pack disabled; after five minutes it counts as a cancel.
        let expiry = Task {
            try await Task.sleep(for: .seconds(300))
            observer.cancel()
        }
        defer {
            expiry.cancel()
            picker.remove(observer)
            picker.isActive = false
        }
        let picked: PickedFilter? = try await withCheckedThrowingContinuation { continuation in
            observer.begin(continuation)
            picker.present(using: .window)
        }
        guard let filter = picked?.filter else { return nil }
        let streamConfiguration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        streamConfiguration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        streamConfiguration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        streamConfiguration.showsCursor = false
        streamConfiguration.ignoreShadowsSingleWindow = true
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfiguration)
        } catch {
            throw Failure.unavailable(error.localizedDescription)
        }
        return try await Task.detached(priority: .userInitiated) { try encode(image) }.value
    }

    /// PNG keeps text sharp; a window too large for that as PNG is tried as
    /// JPEG before it is refused. Off the main actor: a large window takes a
    /// noticeable time to encode.
    nonisolated static func encode(_ image: CGImage) throws -> Captured {
        for (type, options) in [(UTType.png, [:]), (UTType.jpeg, [kCGImageDestinationLossyCompressionQuality: 0.9])] as [(UTType, [CFString: Any])] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            if output.length <= ContextImageInspector.maximumBytes {
                return Captured(data: output as Data, width: image.width, height: image.height)
            }
        }
        throw Failure.tooLarge(width: image.width, height: image.height)
    }
}

/// The filter the picker hands over, carried to the main actor as it is.
private struct PickedFilter: @unchecked Sendable {
    let filter: SCContentFilter
}

/// The picker calls its observers on its own queue; this turns the first
/// answer (a window, a cancellation or a failure) into the one result the
/// capture waits for, and ignores anything after it.
private final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PickedFilter?, Error>?

    func begin(_ continuation: CheckedContinuation<PickedFilter?, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func cancel() {
        finish(.success(nil))
    }

    private func finish(_ result: Result<PickedFilter?, Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<PickedFilter?, Error>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finish(.success(nil))
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        finish(.success(PickedFilter(filter: filter)))
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finish(.failure(WindowCapture.Failure.unavailable(error.localizedDescription)))
    }
}
