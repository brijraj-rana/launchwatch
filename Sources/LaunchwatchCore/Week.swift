import Foundation

// MARK: Outages

/// A stretch when a site was down: from the first failed pulse to the first one that answered again.
public struct Outage: Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// True when the site has not answered since.
    public var ongoing: Bool

    public var length: TimeInterval { end.timeIntervalSince(start) }
}

/// One six hour stretch of the uptime strip.
public struct StripCell: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case up         // checked, and never down
        case down       // down for at least some of it
        case empty      // not checked: the Mac was asleep, or the site was not being watched yet
        case paused     // not checked, because the site was paused
    }

    public var state: State
    public var start: Date
    public var end: Date

    public init(state: State, start: Date, end: Date) {
        self.state = state
        self.start = start
        self.end = end
    }

    /// What the stretch amounted to, for a tooltip.
    public var words: String {
        switch state {
        case .up: return "up"
        case .down: return "down for some of it"
        case .empty: return "not checked"
        case .paused: return "paused"
        }
    }
}

extension Stats {
    /// True for each failed pulse that belongs to a run long enough to be called down. One dropped request is not an outage.
    /// A pause ends a run: failures either side of one are not the same outage.
    static func downFlags(_ samples: [Sample], pauses: [Pause] = []) -> [Bool] {
        var flags = [Bool](repeating: false, count: samples.count)
        var index = 0
        while index < samples.count {
            guard !samples[index].ok else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < samples.count, !samples[end + 1].ok,
                  pauseBegan(after: samples[end].date, upTo: samples[end + 1].date, pauses: pauses) == nil { end += 1 }
            if end - index + 1 >= Detector.failuresBeforeDown {
                for marked in index...end { flags[marked] = true }
            }
            index = end + 1
        }
        return flags
    }

    /// The outages that touch the window, oldest first, measured the way the "back after" message measures them.
    /// An outage that a pause interrupts ends where the pause begins, so paused time is never counted as downtime.
    public static func outages(_ samples: [Sample], now: Date, window: TimeInterval = keep, pauses: [Pause] = []) -> [Outage] {
        let opening = now.addingTimeInterval(-window)
        var found: [Outage] = []
        var first: Date?
        var run = 0
        var previous: Date?
        /// Closes the run under way if a pause began between the last reading and `moment`.
        func breakAtPause(before moment: Date) {
            guard let last = previous, let began = pauseBegan(after: last, upTo: moment, pauses: pauses) else { return }
            if run >= Detector.failuresBeforeDown, let first, began > opening {
                found.append(Outage(start: max(first, opening), end: began, ongoing: false))
            }
            first = nil
            run = 0
        }
        for sample in samples where sample.date <= now {
            breakAtPause(before: sample.date)
            previous = sample.date
            if sample.ok {
                if run >= Detector.failuresBeforeDown, let first, sample.date > opening {
                    found.append(Outage(start: max(first, opening), end: sample.date, ongoing: false))
                }
                first = nil
                run = 0
            } else {
                if first == nil { first = sample.date }
                run += 1
            }
        }
        breakAtPause(before: now)
        if run >= Detector.failuresBeforeDown, let first {
            found.append(Outage(start: max(first, opening), end: now, ongoing: true))
        }
        return found
    }

    /// When the stretch that contains `now` began: midnight, 6:00, 12:00 or 18:00 on the calendar's clock.
    static func stretchStart(_ now: Date, calendar: Calendar, length: TimeInterval) -> Date {
        let midnight = calendar.startOfDay(for: now)
        let whole = (now.timeIntervalSince(midnight) / length).rounded(.down)
        return midnight.addingTimeInterval(whole * length)
    }

    /// The last week as 28 cells, four a day, oldest first. The last cell is the stretch still under way.
    /// A cell is down when the site was down for any of it, up when it was checked and never down, and empty when it was not checked.
    /// A cell with no checks in it that a pause reaches into is paused.
    public static func strip(_ samples: [Sample], now: Date, calendar: Calendar = .current, days: Int = 7, perDay: Int = 4, pauses: [Pause] = []) -> [StripCell] {
        let count = days * perDay
        guard count > 0 else { return [] }
        let length = 86_400.0 / Double(perDay)
        let first = stretchStart(now, calendar: calendar, length: length).addingTimeInterval(-Double(count - 1) * length)
        var states = [StripCell.State](repeating: .empty, count: count)
        let down = downFlags(samples, pauses: pauses)
        for (position, sample) in samples.enumerated() {
            let offset = sample.date.timeIntervalSince(first)
            guard offset >= 0, sample.date <= now else { continue }
            let index = min(count - 1, Int(offset / length))
            if down[position] {
                states[index] = .down
            } else if states[index] == .empty {
                states[index] = .up
            }
        }
        return (0..<count).map { index in
            let start = first.addingTimeInterval(Double(index) * length)
            let end = start.addingTimeInterval(length)
            var state = states[index]
            if state == .empty, pauses.contains(where: { $0.since < min(end, now) && ($0.until ?? now) > start }) { state = .paused }
            return StripCell(state: state, start: start, end: end)
        }
    }

    /// The strip in one sentence, for VoiceOver.
    public static func stripSummary(_ cells: [StripCell]) -> String {
        let down = cells.filter { $0.state == .down }.count
        let paused = cells.filter { $0.state == .paused }.count
        let empty = cells.filter { $0.state == .empty }.count + paused
        guard empty < cells.count else { return paused == cells.count ? "Paused through the last 7 days." : "No checks in the last 7 days." }
        let unchecked = empty == 0 ? "" : " Not checked during \(empty)\(paused == 0 ? "" : ", paused for \(paused) of them")."
        if down == 0 {
            return empty == 0 ? "Up through all of the last 7 days." : "Up whenever it was checked in the last 7 days.\(unchecked)"
        }
        return "Down during \(down) of the \(cells.count) six hour stretches in the last 7 days.\(unchecked)"
    }
}

// MARK: The weekly summary

/// What happened to every site over a week, kept as facts so the sentence can be written whenever it is read.
public struct WeekSummary: Codable, Equatable, Sendable {
    public struct LongestOutage: Codable, Equatable, Sendable {
        public var host: String
        public var seconds: TimeInterval

        public init(host: String, seconds: TimeInterval) {
            self.host = host
            self.seconds = seconds
        }
    }

    public struct Certificate: Codable, Equatable, Sendable {
        public var host: String
        public var expiry: Date

        public init(host: String, expiry: Date) {
            self.host = host
            self.expiry = expiry
        }
    }

    /// When it was written.
    public var date: Date
    public var sites: Int
    /// The one site, when there is only one.
    public var onlyHost: String?
    /// The share of all pulses that answered.
    public var uptime: Double
    public var outages: Int
    public var longest: LongestOutage?
    /// Certificates that had run out or were about to, soonest first.
    public var certificates: [Certificate]
    /// Sites whose score fell.
    public var scoreDrops: Int
    /// Other things an audit found changed: a noindex, robots.txt, the sitemap, the home page title or canonical, a new problem.
    public var auditChanges: Int

    public init(date: Date, sites: Int, onlyHost: String? = nil, uptime: Double, outages: Int = 0, longest: LongestOutage? = nil,
                certificates: [Certificate] = [], scoreDrops: Int = 0, auditChanges: Int = 0) {
        self.date = date
        self.sites = sites
        self.onlyHost = onlyHost
        self.uptime = uptime
        self.outages = outages
        self.longest = longest
        self.certificates = certificates
        self.scoreDrops = scoreDrops
        self.auditChanges = auditChanges
    }

    /// A week needs at least a day of checks behind it before anything is said about it.
    static let stretchesNeeded = 4
    static let audited: Set<EventKind> = [.noindex, .robotsBlocked, .sitemapGone, .titleChanged, .canonicalChanged, .newProblem]

    /// Reads the week off the stored samples and events. Nil when there are no sites, or too few checks to say anything honest.
    public static func make(entries: [Entry], samples: [UUID: [Sample]], events: [SiteEvent], now: Date, window: TimeInterval = Stats.keep) -> WeekSummary? {
        guard !entries.isEmpty else { return nil }
        let ids = Set(entries.map(\.site.id))
        let pulses = entries.map { Stats.unpaused(Stats.recent(samples[$0.site.id] ?? [], now: now, window: window), pauses: Pausing.spans($0.state, now: now)) }
        let all = pulses.flatMap { $0 }
        let covered = Stats.buckets(all, now: now, window: window, count: 28).filter { $0 != .empty }.count
        guard covered >= stretchesNeeded else { return nil }

        var outages = 0
        var longest: LongestOutage?
        for entry in entries {
            for outage in Stats.outages(samples[entry.site.id] ?? [], now: now, window: window, pauses: Pausing.spans(entry.state, now: now)) {
                outages += 1
                if outage.length > (longest?.seconds ?? -1) { longest = LongestOutage(host: entry.site.host, seconds: outage.length) }
            }
        }

        // A paused site raises nothing, here as everywhere else.
        let certificates = entries.filter { !Pausing.isPaused($0.state, now: now) }.compactMap { entry -> Certificate? in
            guard let expiry = entry.state.certificateExpiry, CertificateStage.of(expiry: expiry, now: now) >= .soon else { return nil }
            return Certificate(host: entry.site.host, expiry: expiry)
        }.sorted { $0.expiry < $1.expiry }

        let opening = now.addingTimeInterval(-window)
        let recent = events.filter { ids.contains($0.site) && $0.date >= opening && $0.date <= now }
        let fallen = Set(recent.filter { $0.kind == .scoreDropped }.map(\.site))

        return WeekSummary(date: now, sites: entries.count, onlyHost: entries.count == 1 ? entries[0].site.host : nil,
                           uptime: Double(all.filter(\.ok).count) / Double(all.count),
                           outages: outages, longest: longest, certificates: certificates,
                           scoreDrops: fallen.count,
                           auditChanges: recent.filter { audited.contains($0.kind) }.count)
    }

    /// Nothing went wrong and nothing is about to.
    public var uneventful: Bool {
        outages == 0 && certificates.isEmpty && scoreDrops == 0 && auditChanges == 0
    }

    /// The summary without "Last week" in front, starting with a capital where a sentence would: the body of the notification.
    public func body(now: Date) -> String {
        if uneventful {
            if sites == 1 { return "\(onlyHost ?? "The site") stayed up." }
            return sites == 2 ? "Both sites stayed up." : "All \(sites) sites stayed up."
        }
        var parts = [Words.count(sites, "site", "sites"), "\(Words.percent(uptime)) up"]
        if let longest, outages > 0 {
            let length = Words.duration(longest.seconds)
            parts.append(outages == 1 ? "1 outage (\(longest.host), \(length))" : "\(outages) outages (the longest on \(longest.host), \(length))")
        }
        if let first = certificates.first {
            let others = certificates.count - 1
            let more = others == 0 ? "" : " (\(others) more within \(Int(CertificateStage.soonDays)) days)"
            parts.append("\(first.host)'s certificate \(Words.expiry(first.expiry, now: now))\(more)")
        }
        if scoreDrops > 0 {
            parts.append(scoreDrops == 1 ? "1 score fell" : "\(scoreDrops) scores fell")
        }
        if auditChanges > 0 {
            parts.append("the audit flagged \(Words.count(auditChanges, "change", "changes"))")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// The whole thing in one sentence, as the panel shows it: "Last week: all 6 sites stayed up."
    /// `now` matters only to a certificate, which is counted down from the day the sentence is read.
    public func text(now: Date) -> String {
        let body = body(now: now)
        // "All" and "Both" open the notification; in the middle of this sentence they are ordinary words.
        let opening = uneventful && sites > 1 ? body.prefix(1).lowercased() + body.dropFirst() : body
        return "Last week: \(opening)"
    }
}

/// Decides when the weekly summary is owed. Pure: the clock and the calendar are arguments.
public enum Weekly {
    /// Monday, in the numbering `Calendar` uses.
    public static let weekday = 2
    public static let hour = 9
    /// Two Monday mornings closer together than this are the same week seen from two time zones.
    static let sameWeek: TimeInterval = 3.5 * 86_400
    /// A week already dealt with that lies further ahead than this means the clock was wrong when it was recorded.
    static let tooFarAhead: TimeInterval = 7 * 86_400

    /// The latest Monday 9:00, local time, that is not after `now`.
    public static func moment(onOrBefore now: Date, calendar: Calendar, weekday: Int = weekday, hour: Int = hour) -> Date? {
        var wanted = DateComponents()
        wanted.weekday = weekday
        wanted.hour = hour
        wanted.minute = 0
        wanted.second = 0
        // The search is for a time strictly before its starting point, so start a second late to include 9:00 itself.
        return calendar.nextDate(after: now.addingTimeInterval(1), matching: wanted, matchingPolicy: .nextTime, direction: .backward)
    }

    /// The Monday morning a summary is owed for, or nil when that week has been dealt with.
    /// A Mac that slept through Monday gets its summary at the first check afterwards, and only one however many weeks it slept.
    public static func due(handled: Date?, now: Date, calendar: Calendar) -> Date? {
        guard let moment = moment(onOrBefore: now, calendar: calendar) else { return nil }
        guard let handled else { return moment }
        // Not after `handled`: the clock was set back, or nothing has come round yet. Soon after it: the time zone moved.
        return moment.timeIntervalSince(handled) >= sameWeek ? moment : nil
    }

    /// The record of the last week dealt with, corrected if it could never come round: a clock that was once set far
    /// ahead would otherwise silence the summary until the real date caught up. The current week counts as dealt with.
    public static func settled(handled: Date?, now: Date, calendar: Calendar) -> Date? {
        guard let handled, handled.timeIntervalSince(now) > tooFarAhead else { return handled }
        return moment(onOrBefore: now, calendar: calendar) ?? handled
    }
}
