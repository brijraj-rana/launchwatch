import Foundation
import LaunchcheckCore

public enum AddOutcome: Equatable, Sendable {
    case added(Site)
    case invalid
    case duplicate(String)
    case noAnswer(host: String, status: Int, reason: String)
    case offline

    /// What to say under the field when the site was not added.
    public var sentence: String? {
        switch self {
        case .added: return nil
        case .invalid: return "That does not look like a web address."
        case .duplicate(let host): return "You are already watching \(host)."
        case .noAnswer(let host, let status, let reason):
            return status == 0 ? "\(host) did not answer: \(reason)." : "\(host) answered with error \(status), so it was not added."
        case .offline: return "This Mac is offline, so the site could not be checked."
        }
    }
}

public struct PulseOutcome: Equatable, Sendable {
    public var events: [SiteEvent] = []
    /// At least one pulse failed because this Mac has no connection. Those pulses were thrown away.
    public var offline = false
    public var pulsed = 0
}

/// Owns the watched sites: runs checks, folds the results in, keeps the files up to date.
public actor Watcher {
    public static let eventsKept = 300
    public static let eventsKeptFor: TimeInterval = 30 * 86_400

    private let store: Store
    private let pulser: Pulser
    private let auditor: SiteAuditing
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private var library: Library
    private var samples: [UUID: [Sample]] = [:]

    public init(store: Store, pulser: Pulser = URLSessionPulser(), auditor: SiteAuditing = EngineAuditor(), clock: @escaping @Sendable () -> Date = { Date() },
                calendar: Calendar = .autoupdatingCurrent) {
        self.store = store
        self.pulser = pulser
        self.auditor = auditor
        self.clock = clock
        self.calendar = calendar
        let library = store.loadLibrary()
        self.library = library
        var samples: [UUID: [Sample]] = [:]
        for entry in library.entries { samples[entry.site.id] = store.samples(for: entry.site.id) }
        self.samples = samples
    }

    // MARK: Reading

    public var settings: WatchSettings { library.settings }
    public var entries: [Entry] { library.entries }
    public var events: [SiteEvent] { library.events }

    public func summaries() -> [SiteSummary] {
        let now = clock()
        return SiteSummary.sorted(library.entries.map { SiteSummary.make($0, samples: samples[$0.site.id] ?? [], events: library.events, now: now, calendar: calendar) })
    }

    /// The latest weekly summary, or nil before the first one.
    public var summary: WeekSummary? { library.summary }

    public func pulsesDue() -> [UUID] {
        Scheduler.pulsesDue(library.entries, settings: library.settings, now: clock())
    }

    public func auditsDue() -> [UUID] {
        Scheduler.auditsDue(library.entries, settings: library.settings, now: clock())
    }

    public func nextPulse() -> Date? {
        Scheduler.nextPulse(library.entries, settings: library.settings, now: clock())
    }

    /// The newest pulse of any site.
    public func lastChecked() -> Date? {
        library.entries.compactMap(\.state.lastPulse).max()
    }

    // MARK: Changing

    public func set(_ settings: WatchSettings) {
        library.settings = settings
        store.save(library)
    }

    /// Adds a site after one pulse proves it answers.
    public func add(_ input: String) async -> AddOutcome {
        guard let entered = Auditor.siteURL(from: input), let host = entered.host?.lowercased(),
              let root = URL(string: "\(entered.scheme?.lowercased() ?? "https")://\(host)\(entered.port.map { ":\($0)" } ?? "")/") else { return .invalid }
        if library.entries.contains(where: { $0.site.host == host }) { return .duplicate(host) }

        let result = await pulser.pulse(root)
        if result.offline { return .offline }
        guard result.ok else { return .noAnswer(host: host, status: result.status, reason: result.reason) }
        if library.entries.contains(where: { $0.site.host == host }) { return .duplicate(host) }

        let now = clock()
        let site = Site(url: root.absoluteString, host: host, added: now)
        let folded = Detector.afterPulse(site: site, state: SiteState(), result: result, history: [], now: now)
        library.entries.append(Entry(site: site, state: folded.state))
        samples[site.id] = [Sample(date: now, status: result.status, milliseconds: result.milliseconds)]
        store.save(samples[site.id] ?? [], for: site.id)
        record(folded.events, now: now)
        store.save(library)
        return .added(site)
    }

    public func remove(_ id: UUID) {
        library.entries.removeAll { $0.site.id == id }
        library.events.removeAll { $0.site == id }
        samples[id] = nil
        store.forget(id)
        store.save(library)
    }

    /// Pulses the given sites at once and returns what is newly worth telling.
    public func pulse(_ ids: [UUID]) async -> PulseOutcome {
        let wanted = Set(ids)
        let targets = library.entries.map(\.site).filter { wanted.contains($0.id) }
        guard !targets.isEmpty else { return PulseOutcome() }

        let pulser = self.pulser
        let results = await withTaskGroup(of: (UUID, PulseResult).self) { group -> [UUID: PulseResult] in
            for site in targets {
                guard let url = URL(string: site.url) else { continue }
                group.addTask { (site.id, await pulser.pulse(url)) }
            }
            var all: [UUID: PulseResult] = [:]
            for await (id, result) in group { all[id] = result }
            return all
        }

        let now = clock()
        var outcome = PulseOutcome()
        for site in targets {
            guard let result = results[site.id] else { continue }
            // No connection on this Mac says nothing about the site, so nothing is recorded.
            if result.offline {
                outcome.offline = true
                continue
            }
            guard let index = library.entries.firstIndex(where: { $0.site.id == site.id }) else { continue }
            let history = samples[site.id] ?? []
            let folded = Detector.afterPulse(site: site, state: library.entries[index].state, result: result, history: history, now: now)
            library.entries[index].state = folded.state
            let kept = Stats.trimmed(history + [Sample(date: now, status: result.status, milliseconds: result.milliseconds)], now: now)
            samples[site.id] = kept
            store.save(kept, for: site.id)
            outcome.events += folded.events
            outcome.pulsed += 1
        }
        record(outcome.events, now: now)
        store.save(library)
        return outcome
    }

    public func pulseDue() async -> PulseOutcome {
        await pulse(pulsesDue())
    }

    /// Runs the audit for one site and compares it with the one before.
    public func audit(_ id: UUID) async -> [SiteEvent] {
        guard let index = library.entries.firstIndex(where: { $0.site.id == id }) else { return [] }
        let site = library.entries[index].site
        library.entries[index].state.lastAuditAttempt = clock()
        store.save(library)

        guard let report = try? await auditor.audit(site.url) else { return [] }
        guard let index = library.entries.firstIndex(where: { $0.site.id == id }) else { return [] }
        let now = clock()
        let folded = Detector.afterAudit(site: site, state: library.entries[index].state, previous: store.report(for: id), current: report, now: now)
        library.entries[index].state = folded.state
        store.save(report, for: id)
        record(folded.events, now: now)
        store.save(library)
        return folded.events
    }

    /// Called at every due-check. Once Monday morning has passed it deals with that week exactly once: it returns the
    /// summary to announce, or nil when there is nothing to say, the setting is off, or the week has been dealt with.
    public func weeklySummaryIfDue() -> WeekSummary? {
        let now = clock()
        let settled = Weekly.settled(handled: library.weekHandled, now: now, calendar: calendar)
        guard let moment = Weekly.due(handled: settled, now: now, calendar: calendar) else {
            if settled != library.weekHandled {
                library.weekHandled = settled
                store.save(library)
            }
            return nil
        }
        library.weekHandled = moment
        defer { store.save(library) }
        guard library.settings.weeklySummary else { return nil }
        // A site added after Monday morning has no week to look back on yet.
        let watched = library.entries.filter { $0.site.added < moment }
        guard let summary = WeekSummary.make(entries: watched, samples: samples, events: library.events, now: now) else { return nil }
        library.summary = summary
        return summary
    }

    /// What the summary would say if it were written now, whether or not one is due. Changes nothing.
    public func summaryNow() -> WeekSummary? {
        WeekSummary.make(entries: library.entries, samples: samples, events: library.events, now: clock())
    }

    private func record(_ events: [SiteEvent], now: Date) {
        guard !events.isEmpty || !library.events.isEmpty else { return }
        let oldest = now.addingTimeInterval(-Self.eventsKeptFor)
        library.events = Array((library.events + events).filter { $0.date >= oldest }.suffix(Self.eventsKept))
    }
}
