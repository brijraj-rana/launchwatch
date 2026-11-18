import Foundation

/// One slice of the sparkline.
public enum Bucket: Equatable, Sendable {
    case empty          // nothing was measured
    case up(Int)        // answered, in this many milliseconds on average
    case down           // at least one pulse failed
}

public enum Stats {
    public static let keep: TimeInterval = 7 * 86_400

    public static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The median response time of the pulses that answered within the window.
    public static func medianResponse(_ samples: [Sample], now: Date, window: TimeInterval = 86_400) -> Int? {
        median(recent(samples, now: now, window: window).filter(\.ok).map(\.milliseconds))
    }

    /// The share of pulses that answered, or nil when there are none.
    public static func uptime(_ samples: [Sample], now: Date, window: TimeInterval = keep) -> Double? {
        let inWindow = recent(samples, now: now, window: window)
        guard !inWindow.isEmpty else { return nil }
        return Double(inWindow.filter(\.ok).count) / Double(inWindow.count)
    }

    /// The window cut into equal slices, oldest first, for the sparkline.
    public static func buckets(_ samples: [Sample], now: Date, window: TimeInterval = 86_400, count: Int = 48) -> [Bucket] {
        guard count > 0 else { return [] }
        let start = now.addingTimeInterval(-window)
        let width = window / Double(count)
        var sums = [Int](repeating: 0, count: count)
        var hits = [Int](repeating: 0, count: count)
        var failed = [Bool](repeating: false, count: count)
        for sample in samples {
            let offset = sample.date.timeIntervalSince(start)
            guard offset >= 0, sample.date <= now else { continue }
            let index = min(count - 1, Int(offset / width))
            if sample.ok {
                sums[index] += sample.milliseconds
                hits[index] += 1
            } else {
                failed[index] = true
            }
        }
        return (0..<count).map { failed[$0] ? .down : (hits[$0] > 0 ? .up(sums[$0] / hits[$0]) : .empty) }
    }

    public static func recent(_ samples: [Sample], now: Date, window: TimeInterval) -> [Sample] {
        let start = now.addingTimeInterval(-window)
        return samples.filter { $0.date >= start && $0.date <= now }
    }

    /// Drops samples older than a week.
    public static func trimmed(_ samples: [Sample], now: Date) -> [Sample] {
        let start = now.addingTimeInterval(-keep)
        guard let first = samples.first, first.date < start else { return samples }
        return samples.filter { $0.date >= start }
    }
}
