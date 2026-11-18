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

    /// The share of pulses that answered, or nil when there are none. Time spent paused is left out:
    /// nothing is checked then, and a reading that slipped in anyway is not counted.
    public static func uptime(_ samples: [Sample], now: Date, window: TimeInterval = keep, pauses: [Pause] = []) -> Double? {
        let inWindow = unpaused(recent(samples, now: now, window: window), pauses: pauses)
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

    /// The samples that were not taken during a pause.
    public static func unpaused(_ samples: [Sample], pauses: [Pause]) -> [Sample] {
        guard !pauses.isEmpty else { return samples }
        return samples.filter { sample in
            !pauses.contains { sample.date >= $0.since && ($0.until.map { sample.date < $0 } ?? true) }
        }
    }

    /// True when a pause began after `earlier` and no later than `later`, which ends any run of failures between them.
    static func pauseBegan(after earlier: Date, upTo later: Date, pauses: [Pause]) -> Date? {
        pauses.first { $0.since > earlier && $0.since <= later }?.since
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

// MARK: Response chart

/// The last day of response times, ready to draw: finer than the sparkline in the row, with the scale and the usual time worked out.
public struct ResponseChart: Equatable, Sendable {
    /// Quarter hours, oldest first.
    public var buckets: [Bucket]
    /// The usual response time over the window: the line the chart is read against.
    public var median: Int?
    /// The slowest stretch drawn.
    public var slowest: Int?
    public var fastest: Int?

    public init(buckets: [Bucket], median: Int?, slowest: Int? = nil, fastest: Int? = nil) {
        self.buckets = buckets
        self.median = median
        self.slowest = slowest
        self.fastest = fastest
    }

    public static let empty = ResponseChart(buckets: [], median: nil)

    /// The time at the top edge. Twice the usual time, so a steady site draws a calm line through the middle
    /// and only a real spike reaches the top.
    public var top: Int {
        max(slowest ?? 1, (median ?? 1) * 2, 1)
    }

    /// How far up the chart a time sits, from 0 at the floor to 1 at the top.
    public func height(of milliseconds: Int) -> Double {
        min(1, max(0, Double(milliseconds) / Double(top)))
    }

    /// True when there is at least one reading to draw.
    public var hasReadings: Bool {
        buckets.contains { $0 != .empty }
    }

    /// The chart in one sentence, for VoiceOver.
    public var spoken: String {
        guard let median, let slowest else { return "No response times in the last 24 hours." }
        let outages = buckets.filter { $0 == .down }.count
        let failed = outages == 0 ? "" : " Some checks failed."
        return "Response over the last 24 hours: usually \(Words.time(median)), slowest \(Words.time(slowest)).\(failed)"
    }
}

extension Stats {
    /// The stored pulses of the last day as a chart. Nothing is fetched.
    public static func chart(_ samples: [Sample], now: Date, window: TimeInterval = 86_400, count: Int = 96) -> ResponseChart {
        let cells = buckets(samples, now: now, window: window, count: count)
        let drawn = cells.compactMap { cell -> Int? in
            if case .up(let ms) = cell { return ms }
            return nil
        }
        return ResponseChart(buckets: cells, median: medianResponse(samples, now: now, window: window), slowest: drawn.max(), fastest: drawn.min())
    }
}
