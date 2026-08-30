import CoreGraphics
import Foundation

/// Restores a main-window frame only when it is no longer meaningfully
/// visible on any connected display. This keeps ordinary user positioning
/// untouched while recovering frames left behind by a removed monitor.
public enum WindowFrameRecovery {
    public static func recoveredFrame(
        _ savedFrame: CGRect,
        visibleFrames: [CGRect],
        minimumVisibleSize: CGSize = CGSize(width: 120, height: 80),
        screenInset: CGFloat = 20
    ) -> CGRect {
        guard !visibleFrames.isEmpty else { return savedFrame }
        let isUsable = savedFrame.width.isFinite
            && savedFrame.height.isFinite
            && savedFrame.origin.x.isFinite
            && savedFrame.origin.y.isFinite
            && savedFrame.width > 0
            && savedFrame.height > 0

        if isUsable, visibleFrames.contains(where: { screen in
            let intersection = savedFrame.intersection(screen)
            return !intersection.isNull
                && intersection.width >= minimumVisibleSize.width
                && intersection.height >= minimumVisibleSize.height
        }) {
            return savedFrame
        }

        let target = visibleFrames.max { left, right in
            intersectionArea(savedFrame, left) < intersectionArea(savedFrame, right)
        } ?? visibleFrames[0]
        let usable = target.insetBy(dx: screenInset, dy: screenInset)
        let fallbackWidth = min(1_300, usable.width)
        let fallbackHeight = min(820, usable.height)
        let width = min(isUsable ? savedFrame.width : fallbackWidth, usable.width)
        let height = min(isUsable ? savedFrame.height : fallbackHeight, usable.height)
        return CGRect(
            x: usable.midX - width / 2,
            y: usable.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func intersectionArea(_ frame: CGRect, _ screen: CGRect) -> CGFloat {
        let intersection = frame.intersection(screen)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }
}

/// Geometry rules shared by the durable split store and the SwiftUI divider.
/// Fractions are presentation state only; leaf/process identity stays in the
/// native layout tree.
public enum NativeSplitGeometry {
    public static let defaultFraction = 0.5
    public static let maximumRecordedSplits = 128

    public static func proportionalFraction(firstLeafCount: Int, secondLeafCount: Int) -> Double {
        let first = max(firstLeafCount, 0)
        let second = max(secondLeafCount, 0)
        let total = first + second
        guard total > 0 else { return defaultFraction }
        return Double(first) / Double(total)
    }

    public static func clampedFraction(
        _ fraction: Double,
        availableLength: CGFloat,
        minimumLeafLength: CGFloat
    ) -> Double {
        guard availableLength.isFinite, availableLength > 0 else { return defaultFraction }
        let minimum = min(max(Double(minimumLeafLength / availableLength), 0.05), 0.45)
        let candidate = fraction.isFinite ? fraction : defaultFraction
        return min(max(candidate, minimum), 1 - minimum)
    }

    public static func isValidPath(_ path: String) -> Bool {
        !path.isEmpty
            && path.utf8.count <= 96
            && path.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }
}
