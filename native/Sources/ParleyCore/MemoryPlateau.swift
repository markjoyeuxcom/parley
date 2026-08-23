import Foundation

public enum MemoryPlateauVerdict: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case insufficientSamples
}

/// A robust steady-state comparison for soak runs. Warm-up is excluded, then
/// medians from the first and last thirds are compared. Medians keep a redraw,
/// allocator trim, or one transient sample from deciding the whole run.
public struct MemoryPlateauAssessment: Codable, Equatable, Sendable {
    public let verdict: MemoryPlateauVerdict
    public let sampleCount: Int
    public let evaluatedSampleCount: Int
    public let earlyMedianBytes: UInt64?
    public let lateMedianBytes: UInt64?
    public let peakBytes: UInt64?
    public let growthBytes: Int64?
    public let allowanceBytes: UInt64

    public static func evaluate(
        samples: [UInt64],
        warmupSamples: Int,
        absoluteAllowanceBytes: UInt64,
        relativeAllowance: Double
    ) -> MemoryPlateauAssessment {
        let warmup = min(samples.count, max(0, warmupSamples))
        let steady = Array(samples.dropFirst(warmup))
        guard steady.count >= 6 else {
            return MemoryPlateauAssessment(
                verdict: .insufficientSamples,
                sampleCount: samples.count,
                evaluatedSampleCount: steady.count,
                earlyMedianBytes: nil,
                lateMedianBytes: nil,
                peakBytes: samples.max(),
                growthBytes: nil,
                allowanceBytes: absoluteAllowanceBytes
            )
        }

        let windowSize = max(3, steady.count / 3)
        let early = median(Array(steady.prefix(windowSize)))
        let late = median(Array(steady.suffix(windowSize)))
        let relative = max(0, relativeAllowance)
        let relativeBytes = UInt64(min(Double(UInt64.max), Double(early) * relative))
        let allowance = max(absoluteAllowanceBytes, relativeBytes)
        let growth = signedDifference(late, early)

        return MemoryPlateauAssessment(
            verdict: growth <= Int64(clamping: allowance) ? .passed : .failed,
            sampleCount: samples.count,
            evaluatedSampleCount: steady.count,
            earlyMedianBytes: early,
            lateMedianBytes: late,
            peakBytes: samples.max(),
            growthBytes: growth,
            allowanceBytes: allowance
        )
    }

    private static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
        let lower = sorted[middle - 1]
        let upper = sorted[middle]
        return lower + (upper - lower) / 2
    }

    private static func signedDifference(_ left: UInt64, _ right: UInt64) -> Int64 {
        if left >= right { return Int64(clamping: left - right) }
        let magnitude = Int64(clamping: right - left)
        return magnitude == Int64.max ? Int64.min + 1 : -magnitude
    }
}
