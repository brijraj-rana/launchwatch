import LaunchcheckCore
import XCTest
@testable import LaunchwatchCore

// MARK: Stubs

/// Answers from a script instead of the network.
final class StubPulser: Pulser, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [PulseResult]] = [:]
    private(set) var asked: [String] = []
    /// The hosts whose page was asked for as well as its answer.
    private(set) var read: [String] = []

    /// Queues answers for a host. The last one repeats once the queue runs out.
    func queue(_ host: String, _ results: PulseResult...) {
        lock.lock()
        answers[host, default: []] += results
        lock.unlock()
    }

    func pulse(_ url: URL, readingBody: Bool) async -> PulseResult {
        lock.withLock {
            let host = url.host ?? ""
            asked.append(host)
            if readingBody { read.append(host) }
            guard var list = answers[host], !list.isEmpty else { return PulseResult(status: 0, error: "the address does not exist") }
            let next = list.count > 1 ? list.removeFirst() : list[0]
            answers[host] = list
            return next
        }
    }
}

final class StubAuditor: SiteAuditing, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [Report] = []

    func queue(_ report: Report) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    func audit(_ address: String) async throws -> Report {
        try lock.withLock {
            guard !reports.isEmpty else { throw AuditError.unreachable(address, "no answer") }
            return reports.removeFirst()
        }
    }
}

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

// MARK: Fixtures

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let site = Site(url: "https://acme-rockets.com/", host: "acme-rockets.com", added: start)
private let up = PulseResult(status: 200, milliseconds: 200)
private let refused = PulseResult(status: 0, error: "the server refused the connection")

/// Steady pulses, one every five minutes, ending just before `now`.
private func steady(_ count: Int, milliseconds: Int = 200, until now: Date) -> [Sample] {
    (1...count).reversed().map { Sample(date: now.addingTimeInterval(TimeInterval(-300 * $0)), status: 200, milliseconds: milliseconds) }
}

private func page(_ path: String, title: String = "Acme", canonical: String? = nil, indexable: Bool = true) -> PageSummary {
    PageSummary(url: "https://acme-rockets.com" + path, status: 200, title: title,
                canonical: canonical ?? "https://acme-rockets.com" + path, indexable: indexable)
}

private func report(_ failed: [String] = [], pages: [PageSummary] = [page("/"), page("/pricing")], date: Date = start) -> Report {
    let findings = failed.map { Finding($0, url: URL(string: "https://acme-rockets.com/")) }
    let passed = Check.all.map(\.id).filter { !failed.contains($0) }
    return Report(site: "https://acme-rockets.com/", date: date, pagesChecked: pages.count, pagesFound: pages.count, linksChecked: 10, seconds: 1,
                  findings: findings, passed: passed, pages: pages)
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("launchwatch-tests-\(UUID().uuidString)", isDirectory: true)
}

/// Runs pulses through the detector one after another, as the watcher would.
private func fold(_ results: [PulseResult], from state: SiteState = SiteState(), history: [Sample] = [], every seconds: TimeInterval = 300,
                 startingAt first: Date = start) -> (state: SiteState, events: [SiteEvent]) {
    var state = state
    var history = history
    var events: [SiteEvent] = []
    var now = first
    for result in results {
        let folded = Detector.afterPulse(site: site, state: state, result: result, history: history, now: now)
        state = folded.state
        events += folded.events
        history.append(Sample(date: now, status: result.status, milliseconds: result.milliseconds))
        now += seconds
    }
    return (state, events)
}

// MARK: Pulse events

final class PulseEventTests: XCTestCase {
    func testOneFailedPulseIsNotDown() {
        let result = fold([up, refused])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertFalse(result.state.isDown)
        XCTAssertEqual(result.state.failures, 1)
    }

    func testABlipIsForgotten() {
        let result = fold([up, refused, up, refused, up])
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.state.failures, 0)
    }

    func testTwoFailedPulsesInARowAreDown() {
        let result = fold([up, refused, refused])
        XCTAssertEqual(result.events.map(\.kind), [.down])
        XCTAssertEqual(result.events[0].level, .critical)
        XCTAssertEqual(result.events[0].message, "acme-rockets.com is down: the server refused the connection.")
        XCTAssertTrue(result.state.isDown)
    }

    func testDownIsSaidOnce() {
        let result = fold([up, refused, refused, refused, refused, refused])
        XCTAssertEqual(result.events.map(\.kind), [.down])
    }

    func testErrorStatusCountsAsDown() {
        let result = fold([up, PulseResult(status: 503, milliseconds: 80), PulseResult(status: 503, milliseconds: 80)])
        XCTAssertEqual(result.events.first?.message, "acme-rockets.com is down: it answered with error 503.")
    }

    func testRecoveredSaysHowLongItWasDown() {
        // First failure at +5 min, back at +25 min: down for 20 minutes.
        let result = fold([up, refused, refused, refused, refused, up])
        XCTAssertEqual(result.events.map(\.kind), [.down, .recovered])
        XCTAssertEqual(result.events[1].level, .good)
        XCTAssertEqual(result.events[1].message, "acme-rockets.com is back after 20 minutes.")
        XCTAssertFalse(result.state.isDown)
        XCTAssertNil(result.state.failingSince)
    }

    func testDownAgainAfterRecoveryIsANewEvent() {
        let result = fold([refused, refused, up, refused, refused])
        XCTAssertEqual(result.events.map(\.kind), [.down, .recovered, .down])
    }

    func testSlowIsRelativeToTheSitesOwnMedian() {
        // 1.5 s would be slow for a site that usually takes 200 ms, and normal for one that usually takes 1.2 s.
        let slowPulse = PulseResult(status: 200, milliseconds: 1500)
        let quick = fold([slowPulse, slowPulse], history: steady(20, milliseconds: 200, until: start))
        XCTAssertEqual(quick.events.map(\.kind), [.slow])
        XCTAssertEqual(quick.events[0].message, "acme-rockets.com is slow: it took 1.5 s and usually takes 200 ms.")

        let sluggish = fold([slowPulse, slowPulse], history: steady(20, milliseconds: 1200, until: start))
        XCTAssertTrue(sluggish.events.isEmpty)
    }

    func testOneSlowPulseIsNotSlow() {
        let result = fold([PulseResult(status: 200, milliseconds: 1500), up], history: steady(20, until: start))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertFalse(result.state.slow)
    }

    func testSlowIsSaidOnceAndClearsQuietly() {
        let slowPulse = PulseResult(status: 200, milliseconds: 1500)
        let result = fold([slowPulse, slowPulse, slowPulse, slowPulse, up], history: steady(40, until: start))
        XCTAssertEqual(result.events.map(\.kind), [.slow])
        XCTAssertFalse(result.state.slow)
    }

    func testSlowNeedsEnoughHistory() {
        let slowPulse = PulseResult(status: 200, milliseconds: 5000)
        let result = fold([slowPulse, slowPulse, slowPulse], history: steady(4, until: start))
        XCTAssertTrue(result.events.isEmpty)
    }

    func testSlowThresholdHasAFloor() {
        // A 20 ms site answering in 80 ms is four times its median and still nothing to mention.
        XCTAssertEqual(Detector.slowThreshold(median: 20), 420)
        XCTAssertEqual(Detector.slowThreshold(median: 400), 1200)
    }
}

// MARK: Certificates

final class CertificateTests: XCTestCase {
    private func pulse(daysLeft: Double, state: SiteState = SiteState(), ok: Bool = true) -> (state: SiteState, events: [SiteEvent]) {
        let result = PulseResult(status: ok ? 200 : 0, milliseconds: 100, error: ok ? nil : "its security certificate is not valid",
                                 certificateExpiry: start.addingTimeInterval(daysLeft * 86_400))
        return Detector.afterPulse(site: site, state: state, result: result, history: [], now: start)
    }

    func testStages() {
        XCTAssertEqual(CertificateStage.of(expiry: nil, now: start), .fine)
        XCTAssertEqual(CertificateStage.of(expiry: start.addingTimeInterval(30 * 86_400), now: start), .fine)
        XCTAssertEqual(CertificateStage.of(expiry: start.addingTimeInterval(14 * 86_400), now: start), .soon)
        XCTAssertEqual(CertificateStage.of(expiry: start.addingTimeInterval(3 * 86_400), now: start), .urgent)
        XCTAssertEqual(CertificateStage.of(expiry: start.addingTimeInterval(-60), now: start), .expired)
    }

    func testNothingWhileThereIsPlentyOfTime() {
        XCTAssertTrue(pulse(daysLeft: 60).events.isEmpty)
    }

    func testEachThresholdIsSaidOnce() {
        var state = SiteState()
        var kinds: [EventKind] = []
        for days in [20.0, 13.5, 13.4, 9.5, 2.5, 2.4, 1.5, 0.5] {
            let folded = pulse(daysLeft: days, state: state)
            state = folded.state
            kinds += folded.events.map(\.kind)
        }
        XCTAssertEqual(kinds, [.certificateSoon, .certificateUrgent])
    }

    func testWording() {
        XCTAssertEqual(pulse(daysLeft: 9.5).events.first?.message, "The certificate for acme-rockets.com expires in 9 days.")
        XCTAssertEqual(pulse(daysLeft: 9.5).events.first?.level, .warning)
        XCTAssertEqual(pulse(daysLeft: 1.5).events.first?.message, "The certificate for acme-rockets.com expires tomorrow.")
        XCTAssertEqual(pulse(daysLeft: 1.5).events.first?.level, .critical)
    }

    func testExpiredIsSaidInsteadOfDown() {
        var state = pulse(daysLeft: 2).state
        var events: [SiteEvent] = []
        for _ in 0..<3 {
            let folded = pulse(daysLeft: -0.1, state: state, ok: false)
            state = folded.state
            events += folded.events
        }
        XCTAssertEqual(events.map(\.kind), [.certificateExpired])
        XCTAssertTrue(state.isDown)
        XCTAssertEqual(Health.of(state, now: start).note, "Certificate has expired")
    }

    func testARenewedCertificateCanWarnAgainNextTime() {
        var state = pulse(daysLeft: 10).state
        state = pulse(daysLeft: 90, state: state).state
        XCTAssertEqual(state.certificateStage, .fine)
        XCTAssertEqual(pulse(daysLeft: 12, state: state).events.map(\.kind), [.certificateSoon])
    }

    func testAPulseWithoutACertificateKeepsTheLastKnownDate() {
        let state = pulse(daysLeft: 40).state
        let folded = Detector.afterPulse(site: site, state: state, result: up, history: [], now: start)
        XCTAssertEqual(folded.state.certificateExpiry, start.addingTimeInterval(40 * 86_400))
    }
}

// MARK: Audit events

final class AuditEventTests: XCTestCase {
    private func audit(_ before: Report?, _ after: Report) -> (state: SiteState, events: [SiteEvent]) {
        Detector.afterAudit(site: site, state: SiteState(), previous: before, current: after, now: start)
    }

    func testFirstAuditRecordsTheScoreAndSaysNothing() {
        let result = audit(nil, report(["sitemap.missing", "title.missing"]))
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertNotNil(result.state.score)
        XCTAssertEqual(result.state.blockers, 1)
        XCTAssertEqual(result.state.audited, start)
    }

    func testNothingChangedSaysNothing() {
        let same = report(["description.missing"])
        XCTAssertTrue(audit(same, same).events.isEmpty)
        XCTAssertNil(audit(same, same).state.auditFlag)
    }

    func testNoindexAppearing() {
        let after = report(["page.noindex"], pages: [page("/"), page("/pricing", indexable: false)])
        let result = audit(report(), after)
        XCTAssertEqual(result.events.first?.kind, .noindex)
        XCTAssertEqual(result.events.first?.message, "A noindex appeared on /pricing of acme-rockets.com, so search engines will drop it.")
        XCTAssertFalse(result.events.contains { $0.kind == .newProblem }, "noindex is reported once, in its own words")
        XCTAssertEqual(result.state.auditFlag?.level, .critical)

        // Unchanged at the next audit: nothing more to say.
        XCTAssertFalse(audit(after, after).events.contains { $0.kind == .noindex })
    }

    func testNoindexOnTheHomePage() {
        let result = audit(report(), report(["page.noindex"], pages: [page("/", indexable: false), page("/pricing")]))
        XCTAssertEqual(result.events.first?.brief, "A noindex appeared on the home page.")
        XCTAssertTrue(result.state.homeNoindex)
        XCTAssertEqual(Health.of(withPulse(result.state), now: start).condition, .critical)
    }

    func testRobotsBlockingEverything() {
        let result = audit(report(), report(["robots.blocks-all"]))
        XCTAssertTrue(result.events.contains { $0.kind == .robotsBlocked && $0.level == .critical })
        XCTAssertFalse(result.events.contains { $0.kind == .newProblem })
        XCTAssertTrue(result.state.robotsBlocked)
    }

    func testSitemapDisappearing() {
        let result = audit(report(), report(["sitemap.missing"]))
        XCTAssertTrue(result.events.contains { $0.kind == .sitemapGone && $0.message == "The sitemap for acme-rockets.com has disappeared." })
        // A site that never had one is not news.
        XCTAssertFalse(audit(report(["sitemap.missing"]), report(["sitemap.missing"])).events.contains { $0.kind == .sitemapGone })
    }

    func testHomeTitleAndCanonicalChanging() {
        let after = report(pages: [page("/", title: "Coming soon", canonical: "https://staging.acme-rockets.com/"), page("/pricing")])
        let events = audit(report(), after).events
        XCTAssertEqual(events.first { $0.kind == .titleChanged }?.message, "The home page title of acme-rockets.com changed to “Coming soon”.")
        XCTAssertEqual(events.first { $0.kind == .canonicalChanged }?.brief, "Home page canonical now points to https://staging.acme-rockets.com/.")
    }

    func testOtherPagesChangingTitleIsNotAnEvent() {
        let after = report(pages: [page("/"), page("/pricing", title: "New pricing")])
        XCTAssertTrue(audit(report(), after).events.isEmpty)
    }

    func testTrailingSlashOnACanonicalIsNotAChange() {
        let after = report(pages: [page("/", canonical: "https://acme-rockets.com"), page("/pricing")])
        XCTAssertTrue(audit(report(), after).events.isEmpty)
    }

    func testNewFixBeforeLaunchProblem() {
        let events = audit(report(), report(["links.internal"])).events
        XCTAssertEqual(events.first { $0.kind == .newProblem }?.message, "New problem on acme-rockets.com: broken links between pages.")
    }

    func testNewWarningAloneIsNotAnEvent() {
        XCTAssertFalse(audit(report(), report(["links.empty"])).events.contains { $0.kind == .newProblem })
    }

    func testScoreDropSaysWhatChanged() {
        let before = report()
        let after = report(["title.missing", "description.missing", "h1.missing"])
        XCTAssertGreaterThanOrEqual(before.score - after.score, 5)
        let drop = audit(before, after).events.first { $0.kind == .scoreDropped }
        XCTAssertEqual(drop?.level, .warning)
        XCTAssertEqual(drop?.message, "The score for acme-rockets.com fell from \(before.score) to \(after.score), new since last time: pages have no title; pages have no meta description.")
    }

    func testSmallScoreDropIsNotAnEvent() {
        let after = report(["favicon.missing"])
        XCTAssertLessThan(report().score - after.score, 5)
        XCTAssertFalse(audit(report(), after).events.contains { $0.kind == .scoreDropped })
    }

    func testNoDashesOrExclamationMarksInAnyMessage() {
        let after = report(["page.noindex", "robots.blocks-all", "sitemap.missing", "links.internal", "title.missing", "h1.missing"],
                           pages: [page("/", title: "Other", canonical: "https://x.example/", indexable: false), page("/pricing")])
        var all = audit(report(), after).events
        all += fold([up, refused, refused, up]).events
        all += fold([PulseResult(status: 200, milliseconds: 1500), PulseResult(status: 200, milliseconds: 1500)], history: steady(20, until: start)).events
        XCTAssertGreaterThan(all.count, 6)
        for event in all {
            for banned in ["\u{2014}", "\u{2013}", "!"] {
                XCTAssertFalse(event.message.contains(banned), event.message)
                XCTAssertFalse(event.brief.contains(banned), event.brief)
            }
        }
    }

    private func withPulse(_ state: SiteState) -> SiteState {
        var state = state
        state.lastPulse = start
        return state
    }
}

// MARK: Health and verdict

final class HealthTests: XCTestCase {
    private func summary(_ host: String, _ change: (inout SiteState) -> Void = { _ in }) -> SiteSummary {
        var state = SiteState()
        state.lastPulse = start
        change(&state)
        return SiteSummary.make(Entry(site: Site(url: "https://\(host)/", host: host, added: start), state: state), samples: [], events: [], now: start)
    }

    func testVerdicts() {
        XCTAssertEqual(Verdict.line([], offline: false), "Nothing to watch yet")
        XCTAssertEqual(Verdict.line([summary("a.com")], offline: false), "a.com is fine")
        XCTAssertEqual(Verdict.line((1...6).map { summary("site\($0).com") }, offline: false), "All 6 sites are fine")
        XCTAssertEqual(Verdict.line([summary("a.com"), summary("b.com") { $0.isDown = true }], offline: false), "b.com is down")
        XCTAssertEqual(Verdict.line([summary("a.com"), summary("b.com") { $0.slow = true }], offline: false), "b.com needs a look")
        XCTAssertEqual(Verdict.line([summary("a.com") { $0.slow = true }, summary("b.com") { $0.isDown = true }], offline: false), "b.com is down",
                       "a site that is down is the headline")
        XCTAssertEqual(Verdict.line([summary("a.com") { $0.slow = true }, summary("b.com") { $0.robotsBlocked = true }, summary("c.com")], offline: false),
                       "2 sites need a look")
        XCTAssertEqual(Verdict.line([summary("a.com") { $0.isDown = true }, summary("b.com") { $0.isDown = true }], offline: false), "2 sites are down")
        XCTAssertEqual(Verdict.line([summary("a.com") { $0.isDown = true }], offline: true), "This Mac is offline")
        XCTAssertEqual(Verdict.line([summary("a.com") { $0.lastPulse = nil }], offline: false), "Checking a.com")
    }

    func testTroubleSortsFirst() {
        let sorted = SiteSummary.sorted([
            summary("fine.com"),
            summary("slow.com") { $0.slow = true },
            summary("also-fine.com"),
            summary("down.com") { $0.isDown = true; $0.failingSince = start },
            summary("robots.com") { $0.robotsBlocked = true },
        ])
        XCTAssertEqual(sorted.map(\.site.host), ["down.com", "robots.com", "slow.com", "fine.com", "also-fine.com"])
    }

    func testNotes() {
        XCTAssertNil(summary("a.com").health.note)
        XCTAssertEqual(summary("a.com") { $0.isDown = true; $0.failingSince = start.addingTimeInterval(-720) }.health.note, "Down for 12 minutes")
        XCTAssertEqual(summary("a.com") { $0.certificateStage = .soon; $0.certificateExpiry = start.addingTimeInterval(9.2 * 86_400) }.health.note,
                       "Certificate expires in 9 days")
        XCTAssertEqual(summary("a.com") { $0.failures = 1 }.health.condition, .fine, "one missed pulse does not change the dot")
    }

    func testSpokenSummary() {
        let row = summary("a.com") { $0.score = 92; $0.lastMilliseconds = 240 }
        XCTAssertEqual(row.spoken, "a.com, fine, answered in 240 ms, score 92 of 100")
    }
}

// MARK: Stats

final class StatsTests: XCTestCase {
    func testMedian() {
        XCTAssertNil(Stats.median([]))
        XCTAssertEqual(Stats.median([5]), 5)
        XCTAssertEqual(Stats.median([9, 1, 5]), 5)
        XCTAssertEqual(Stats.median([1, 3, 5, 100]), 4)
    }

    func testUptime() {
        var samples = steady(99, until: start)
        samples.append(Sample(date: start, status: 0, milliseconds: 0))
        XCTAssertEqual(Stats.uptime(samples, now: start), 0.99)
        XCTAssertNil(Stats.uptime([], now: start))
        XCTAssertEqual(Words.percent(0.99), "99%")
        XCTAssertEqual(Words.percent(0.9996), "99.9%")
        XCTAssertEqual(Words.percent(1), "100%")
    }

    func testBucketsMarkOutages() {
        let samples = [
            Sample(date: start.addingTimeInterval(-23.9 * 3600), status: 200, milliseconds: 100),
            Sample(date: start.addingTimeInterval(-23.8 * 3600), status: 200, milliseconds: 300),
            Sample(date: start.addingTimeInterval(-12.1 * 3600), status: 0, milliseconds: 0),
            Sample(date: start.addingTimeInterval(-60), status: 200, milliseconds: 250),
            Sample(date: start.addingTimeInterval(-30 * 3600), status: 0, milliseconds: 0),     // older than the window
        ]
        let buckets = Stats.buckets(samples, now: start, window: 86_400, count: 24)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertEqual(buckets[0], .up(200))
        XCTAssertEqual(buckets[11], .down)
        XCTAssertEqual(buckets[23], .up(250))
        XCTAssertEqual(buckets.filter { $0 == .empty }.count, 21)
    }

    func testSamplesAreKeptForAWeek() {
        let old = Sample(date: start.addingTimeInterval(-8 * 86_400), status: 200, milliseconds: 1)
        let recent = Sample(date: start.addingTimeInterval(-6 * 86_400), status: 200, milliseconds: 2)
        XCTAssertEqual(Stats.trimmed([old, recent], now: start), [recent])
    }

    func testWords() {
        XCTAssertEqual(Words.duration(40), "a minute")
        XCTAssertEqual(Words.duration(12 * 60), "12 minutes")
        XCTAssertEqual(Words.duration(3 * 3600), "3 hours")
        XCTAssertEqual(Words.duration(3 * 86_400), "3 days")
        XCTAssertEqual(Words.time(310), "310 ms")
        XCTAssertEqual(Words.time(2400), "2.4 s")
        XCTAssertEqual(Words.path(of: "https://a.com/"), "the home page")
        XCTAssertEqual(Words.path(of: "https://a.com/pricing"), "/pricing")
    }
}

// MARK: Scheduling

final class SchedulerTests: XCTestCase {
    private let settings = WatchSettings()

    private func state(_ change: (inout SiteState) -> Void) -> SiteState {
        var state = SiteState()
        change(&state)
        return state
    }

    func testANewSiteIsDueAtOnce() {
        XCTAssertTrue(Scheduler.pulseDue(SiteState(), settings: settings, now: start))
        XCTAssertFalse(Scheduler.auditDue(SiteState(), settings: settings, now: start), "the audit waits for a first pulse")
    }

    func testPulseFollowsTheInterval() {
        let pulsed = state { $0.lastPulse = start }
        XCTAssertFalse(Scheduler.pulseDue(pulsed, settings: settings, now: start.addingTimeInterval(120)))
        XCTAssertTrue(Scheduler.pulseDue(pulsed, settings: settings, now: start.addingTimeInterval(300)))

        var quick = settings
        quick.pulseMinutes = 1
        XCTAssertTrue(Scheduler.pulseDue(pulsed, settings: quick, now: start.addingTimeInterval(60)))
    }

    func testAFailedPulseIsRetriedSoon() {
        let failed = state { $0.lastPulse = start; $0.failures = 1 }
        XCTAssertFalse(Scheduler.pulseDue(failed, settings: settings, now: start.addingTimeInterval(10)))
        XCTAssertTrue(Scheduler.pulseDue(failed, settings: settings, now: start.addingTimeInterval(30)))

        // Once it is known to be down it goes back to the usual pace.
        let down = state { $0.lastPulse = start; $0.failures = 2; $0.isDown = true }
        XCTAssertFalse(Scheduler.pulseDue(down, settings: settings, now: start.addingTimeInterval(60)))
    }

    func testEverythingOverdueAfterSleepIsDue() {
        let entries = (0..<3).map { index in
            Entry(site: Site(url: "https://s\(index).com/", host: "s\(index).com", added: start),
                  state: state { $0.lastPulse = start; $0.lastAuditAttempt = start })
        }
        let afterSleep = start.addingTimeInterval(9 * 3600)
        XCTAssertEqual(Scheduler.pulsesDue(entries, settings: settings, now: afterSleep).count, 3)
        XCTAssertEqual(Scheduler.auditsDue(entries, settings: settings, now: afterSleep).count, 3)
        XCTAssertLessThan(Scheduler.nextPulse(entries, settings: settings, now: afterSleep)!, afterSleep)
    }

    func testAuditFollowsItsOwnInterval() {
        let audited = state { $0.lastPulse = start; $0.lastAuditAttempt = start }
        XCTAssertFalse(Scheduler.auditDue(audited, settings: settings, now: start.addingTimeInterval(5 * 3600)))
        XCTAssertTrue(Scheduler.auditDue(audited, settings: settings, now: start.addingTimeInterval(6 * 3600)))
    }

    func testNoAuditWhileASiteIsNotAnswering() {
        XCTAssertFalse(Scheduler.auditDue(state { $0.lastPulse = start; $0.isDown = true; $0.failures = 3 }, settings: settings, now: start))
        XCTAssertFalse(Scheduler.auditDue(state { $0.lastPulse = start; $0.failures = 1 }, settings: settings, now: start))
    }

    func testAClockSetBackDoesNotStallChecks() {
        let future = state { $0.lastPulse = start.addingTimeInterval(86_400) }
        XCTAssertTrue(Scheduler.pulseDue(future, settings: settings, now: start))
    }

    func testNextPulse() {
        XCTAssertNil(Scheduler.nextPulse([], settings: settings, now: start))
        let entry = Entry(site: site, state: state { $0.lastPulse = start })
        XCTAssertEqual(Scheduler.nextPulse([entry], settings: settings, now: start), start.addingTimeInterval(300))
    }
}

// MARK: Persistence

final class StoreTests: XCTestCase {
    func testRoundTrip() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = Store(directory: directory)
        XCTAssertEqual(store.loadLibrary(), Library(), "nothing saved yet reads as empty")

        var state = SiteState()
        state.lastPulse = start
        state.failures = 2
        state.isDown = true
        state.failingSince = start.addingTimeInterval(-300)
        state.certificateExpiry = start.addingTimeInterval(9 * 86_400)
        state.certificateStage = .soon
        state.score = 88
        state.auditFlag = AuditFlag(level: .warning, note: "The sitemap has disappeared")

        var library = Library()
        library.entries = [Entry(site: site, state: state)]
        library.events = [SiteEvent(site: site, kind: .down, level: .critical, message: "acme-rockets.com is down: it did not answer.", brief: "Down: it did not answer.", date: start)]
        library.settings.pulseMinutes = 15
        library.settings.auditHours = 24
        library.settings.notifications = false
        store.save(library)

        let samples = steady(5, until: start)
        store.save(samples, for: site.id)
        let saved = report(["sitemap.missing"])
        store.save(saved, for: site.id)

        let again = Store(directory: directory)
        XCTAssertEqual(again.loadLibrary(), library)
        XCTAssertEqual(again.samples(for: site.id), samples)
        XCTAssertEqual(again.report(for: site.id), saved)

        again.forget(site.id)
        XCTAssertTrue(again.samples(for: site.id).isEmpty)
        XCTAssertNil(again.report(for: site.id))
    }

    func testADamagedFileReadsAsEmpty() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("library.json"))
        XCTAssertEqual(Store(directory: directory).loadLibrary(), Library())
    }
}

// MARK: The watcher, end to end, with stubs

final class WatcherTests: XCTestCase {
    private var directory: URL!
    private var pulser: StubPulser!
    private var auditor: StubAuditor!
    private var clock: TestClock!

    override func setUp() {
        directory = scratch()
        pulser = StubPulser()
        auditor = StubAuditor()
        clock = TestClock(start)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func watcher() -> Watcher {
        let clock = self.clock!
        return Watcher(store: Store(directory: directory), pulser: pulser, auditor: auditor, domains: StubDomains(), sideDoor: StubSideDoor(), clock: { clock.now })
    }

    func testAddingValidatesWithOnePulse() async {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", up)

        let invalid = await watcher.add("not an address")
        XCTAssertEqual(invalid, .invalid)
        let missing = await watcher.add("nowhere.example")
        XCTAssertEqual(missing.sentence, "nowhere.example did not answer: the address does not exist.")

        let added = await watcher.add("  HTTPS://Acme-Rockets.com/pricing ")
        guard case .added(let site) = added else { return XCTFail("expected the site to be added") }
        XCTAssertEqual(site.host, "acme-rockets.com")
        XCTAssertEqual(site.url, "https://acme-rockets.com/")

        let again = await watcher.add("acme-rockets.com")
        XCTAssertEqual(again.sentence, "You are already watching acme-rockets.com.")

        let rows = await watcher.summaries()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].health.condition, .fine)
        XCTAssertEqual(rows[0].state.lastMilliseconds, 200)
    }

    func testAnErrorPageIsNotAdded() async {
        let watcher = watcher()
        pulser.queue("broken.example", PulseResult(status: 404, milliseconds: 50))
        let outcome = await watcher.add("broken.example")
        XCTAssertEqual(outcome.sentence, "broken.example answered with error 404, so it was not added.")
        let entries = await watcher.entries
        XCTAssertTrue(entries.isEmpty)
    }

    func testDownThenRecoveredAcrossScheduledPulses() async {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", up, refused, refused, refused, up)
        _ = await watcher.add("acme-rockets.com")

        clock.advance(300)
        var outcome = await watcher.pulseDue()
        XCTAssertTrue(outcome.events.isEmpty, "one failure is not an outage")
        var due = await watcher.pulsesDue()
        XCTAssertTrue(due.isEmpty, "the retry waits half a minute")

        clock.advance(30)
        outcome = await watcher.pulseDue()
        XCTAssertEqual(outcome.events.map(\.kind), [.down])

        clock.advance(30)
        due = await watcher.pulsesDue()
        XCTAssertTrue(due.isEmpty, "a site known to be down is checked at the usual pace")

        clock.advance(270)
        outcome = await watcher.pulseDue()
        XCTAssertTrue(outcome.events.isEmpty, "still down, already said")

        clock.advance(300)
        outcome = await watcher.pulseDue()
        // First failure at 5:00, back at 15:30.
        XCTAssertEqual(outcome.events.map(\.message), ["acme-rockets.com is back after 11 minutes."])

        let events = await watcher.events
        XCTAssertEqual(events.map(\.kind), [.down, .recovered])
    }

    func testOfflinePulsesAreThrownAway() async {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", up, PulseResult(status: 0, error: "this Mac is offline", offline: true))
        _ = await watcher.add("acme-rockets.com")

        for _ in 0..<3 {
            clock.advance(300)
            let outcome = await watcher.pulseDue()
            XCTAssertTrue(outcome.offline)
            XCTAssertTrue(outcome.events.isEmpty)
            XCTAssertEqual(outcome.pulsed, 0)
        }
        let rows = await watcher.summaries()
        XCTAssertEqual(rows[0].state.failures, 0)
        XCTAssertEqual(rows[0].health.condition, .fine)
        XCTAssertEqual(rows[0].uptime, 1)
    }

    func testAuditsCompareWithTheOneBefore() async {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", up)
        guard case .added(let site) = await watcher.add("acme-rockets.com") else { return XCTFail("expected the site to be added") }
        auditor.queue(report())
        auditor.queue(report(["robots.blocks-all"]))

        var due = await watcher.auditsDue()
        XCTAssertEqual(due, [site.id])
        var events = await watcher.audit(site.id)
        XCTAssertTrue(events.isEmpty, "the first audit has nothing to compare with")
        due = await watcher.auditsDue()
        XCTAssertTrue(due.isEmpty)

        clock.advance(6 * 3600)
        due = await watcher.auditsDue()
        XCTAssertEqual(due, [site.id])
        events = await watcher.audit(site.id)
        XCTAssertEqual(events.map(\.kind), [.robotsBlocked, .scoreDropped])

        let rows = await watcher.summaries()
        XCTAssertEqual(rows[0].health.note, "robots.txt blocks every crawler")
        XCTAssertEqual(rows[0].events.count, 2)
    }

    func testAFailedAuditIsNotRetriedStraightAway() async {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", up)
        guard case .added(let site) = await watcher.add("acme-rockets.com") else { return XCTFail("expected the site to be added") }
        let events = await watcher.audit(site.id)        // the stub has no report to give
        XCTAssertTrue(events.isEmpty)
        let due = await watcher.auditsDue()
        XCTAssertTrue(due.isEmpty)
        let rows = await watcher.summaries()
        XCTAssertNil(rows[0].state.score)
    }

    func testEverythingSurvivesARestart() async {
        var watcher = watcher()
        pulser.queue("acme-rockets.com", up, refused)
        guard case .added(let site) = await watcher.add("acme-rockets.com") else { return XCTFail("expected the site to be added") }
        var settings = WatchSettings()
        settings.pulseMinutes = 1
        await watcher.set(settings)
        clock.advance(60)
        _ = await watcher.pulseDue()
        clock.advance(30)
        _ = await watcher.pulseDue()
        let before = await watcher.summaries()

        watcher = self.watcher()
        let after = await watcher.summaries()
        XCTAssertEqual(after, before)
        XCTAssertEqual(after[0].events.map(\.kind), [.down])
        let restored = await watcher.settings
        XCTAssertEqual(restored.pulseMinutes, 1)

        await watcher.remove(site.id)
        let fresh = self.watcher()
        let left = await fresh.summaries()
        XCTAssertTrue(left.isEmpty)
        XCTAssertTrue(Store(directory: directory).samples(for: site.id).isEmpty)
    }
}

// MARK: The week: fixtures

/// A calendar that does not depend on where the tests run.
private func calendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in zone: String = "UTC") -> Date {
    calendar(zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Monday 18 January 2027, 9:00 in the morning, UTC. `start` is the Friday before it.
private let monday = date(2027, 1, 18, 9)
private let week: TimeInterval = 7 * 86_400

private func watched(_ host: String, _ change: (inout SiteState) -> Void = { _ in }) -> Entry {
    var state = SiteState()
    change(&state)
    return Entry(site: Site(url: "https://\(host)/", host: host, added: monday.addingTimeInterval(-30 * 86_400)), state: state)
}

/// One pulse an hour for the week before `now`, all answered.
private func hourly(until now: Date) -> [Sample] {
    (1...168).reversed().map { Sample(date: now.addingTimeInterval(-3600 * TimeInterval($0)), status: 200, milliseconds: 200) }
}

/// Failed pulses starting `ago` before `now`, then an answer `length` after the first of them.
private func outage(_ ago: TimeInterval, lasting length: TimeInterval, until now: Date) -> [Sample] {
    let first = now.addingTimeInterval(-ago)
    return [
        Sample(date: first, status: 0, milliseconds: 0),
        Sample(date: first.addingTimeInterval(30), status: 0, milliseconds: 0),
        Sample(date: first.addingTimeInterval(length / 2), status: 0, milliseconds: 0),
        Sample(date: first.addingTimeInterval(length), status: 200, milliseconds: 200),
    ]
}

/// A steady week with one outage in it. Nothing answers while the site is down.
private func hourly(until now: Date, downFrom ago: TimeInterval, lasting length: TimeInterval) -> [Sample] {
    let first = now.addingTimeInterval(-ago)
    let steady = hourly(until: now).filter { $0.date < first || $0.date > first.addingTimeInterval(length) }
    return sorted(steady + outage(ago, lasting: length, until: now))
}

private func sorted(_ samples: [Sample]) -> [Sample] {
    samples.sorted { $0.date < $1.date }
}

private func event(_ kind: EventKind, on entry: Entry, at date: Date) -> SiteEvent {
    SiteEvent(site: entry.site, kind: kind, level: .warning, message: "", brief: "", date: date)
}

// MARK: Weekly summary

final class WeekSummaryTests: XCTestCase {
    private let hosts = ["acme-rockets.com", "tidyhq.io", "northwind-studio.com", "harbour-coffee.co", "fieldnotes.studio", "lumen-bikes.com"]

    private func steadyWeek(_ entries: [Entry]) -> [UUID: [Sample]] {
        var samples: [UUID: [Sample]] = [:]
        for entry in entries { samples[entry.site.id] = hourly(until: monday) }
        return samples
    }

    func testAQuietWeekIsSaidBriefly() {
        let entries = hosts.map { watched($0) }
        let summary = WeekSummary.make(entries: entries, samples: steadyWeek(entries), events: [], now: monday)
        XCTAssertEqual(summary?.text(now: monday), "Last week: all 6 sites stayed up.")
        XCTAssertEqual(summary?.body(now: monday), "All 6 sites stayed up.")
        XCTAssertEqual(summary?.uneventful, true)

        let two = Array(entries.prefix(2))
        XCTAssertEqual(WeekSummary.make(entries: two, samples: steadyWeek(two), events: [], now: monday)?.text(now: monday),
                       "Last week: both sites stayed up.")
        let one = Array(entries.prefix(1))
        let alone = WeekSummary.make(entries: one, samples: steadyWeek(one), events: [], now: monday)
        XCTAssertEqual(alone?.text(now: monday), "Last week: acme-rockets.com stayed up.")
        XCTAssertEqual(alone?.body(now: monday), "acme-rockets.com stayed up.")
    }

    func testOneDroppedRequestDoesNotSpoilAQuietWeek() {
        let entries = hosts.map { watched($0) }
        var samples = steadyWeek(entries)
        let blip = Sample(date: monday.addingTimeInterval(-3600 * 30.5), status: 0, milliseconds: 0)
        samples[entries[0].site.id] = sorted(hourly(until: monday) + [blip])
        let summary = WeekSummary.make(entries: entries, samples: samples, events: [], now: monday)
        XCTAssertEqual(summary?.outages, 0)
        XCTAssertEqual(summary?.text(now: monday), "Last week: all 6 sites stayed up.")
    }

    func testAWeekWithAnOutageACertificateAndAScoreDrop() {
        let entries = hosts.map { host in
            watched(host) { if host == "harbour-coffee.co" { $0.certificateExpiry = monday.addingTimeInterval(9.5 * 86_400) } }
        }
        var samples = steadyWeek(entries)
        samples[entries[0].site.id] = hourly(until: monday, downFrom: 50.5 * 3600, lasting: 12.0 * 60)
        let events = [
            event(.scoreDropped, on: entries[0], at: monday.addingTimeInterval(-86_400)),
            event(.scoreDropped, on: entries[0], at: monday.addingTimeInterval(-9 * 86_400)),       // the week before
            event(.down, on: entries[0], at: monday.addingTimeInterval(-50.5 * 3600)),
        ]
        let summary = WeekSummary.make(entries: entries, samples: samples, events: events, now: monday)
        XCTAssertEqual(summary?.text(now: monday),
                       "Last week: 6 sites, 99.7% up, 1 outage (acme-rockets.com, 12 minutes), harbour-coffee.co's certificate expires in 9 days, 1 score fell.")
        XCTAssertEqual(summary?.body(now: monday),
                       "6 sites, 99.7% up, 1 outage (acme-rockets.com, 12 minutes), harbour-coffee.co's certificate expires in 9 days, 1 score fell.")
        // Read on Friday, the certificate is counted down from Friday.
        XCTAssertEqual(summary?.text(now: monday.addingTimeInterval(4 * 86_400)).contains("certificate expires in 5 days"), true)
    }

    func testSeveralOfEverything() {
        let entries = [
            watched("a.com") { $0.certificateExpiry = monday.addingTimeInterval(-3600) },
            watched("b.com") { $0.certificateExpiry = monday.addingTimeInterval(6.5 * 86_400) },
            watched("c.com") { $0.certificateExpiry = monday.addingTimeInterval(90 * 86_400) },
        ]
        var samples = steadyWeek(entries)
        samples[entries[0].site.id] = hourly(until: monday, downFrom: 100.5 * 3600, lasting: 10.0 * 60)
        samples[entries[1].site.id] = hourly(until: monday, downFrom: 60.5 * 3600, lasting: 2.0 * 3600)
        // c.com went down 20 minutes ago and has not come back.
        samples[entries[2].site.id] = hourly(until: monday) + [
            Sample(date: monday.addingTimeInterval(-20.0 * 60), status: 503, milliseconds: 40),
            Sample(date: monday.addingTimeInterval(-19.5 * 60), status: 503, milliseconds: 40),
        ]
        let events = [
            event(.scoreDropped, on: entries[0], at: monday.addingTimeInterval(-3600)),
            event(.scoreDropped, on: entries[0], at: monday.addingTimeInterval(-7200)),            // the same site twice is one score
            event(.scoreDropped, on: entries[1], at: monday.addingTimeInterval(-3600)),
            event(.noindex, on: entries[2], at: monday.addingTimeInterval(-3600)),
            event(.sitemapGone, on: entries[2], at: monday.addingTimeInterval(-3600)),
            event(.slow, on: entries[2], at: monday.addingTimeInterval(-3600)),                    // not counted
            event(.noindex, on: watched("gone.com"), at: monday.addingTimeInterval(-3600)),        // a site no longer watched
        ]
        let summary = WeekSummary.make(entries: entries, samples: samples, events: events, now: monday)
        XCTAssertEqual(summary?.outages, 3)
        XCTAssertEqual(summary?.longest, WeekSummary.LongestOutage(host: "b.com", seconds: 7200))
        XCTAssertEqual(summary?.certificates.map(\.host), ["a.com", "b.com"])
        XCTAssertEqual(summary?.scoreDrops, 2)
        XCTAssertEqual(summary?.auditChanges, 2)
        let text = summary?.text(now: monday) ?? ""
        XCTAssertTrue(text.hasPrefix("Last week: 3 sites, 9"), text)
        XCTAssertTrue(text.hasSuffix("% up, 3 outages (the longest on b.com, 2 hours), a.com's certificate has expired (1 more within 14 days), 2 scores fell, the audit flagged 2 changes."), text)
        for banned in ["\u{2014}", "\u{2013}", "!"] { XCTAssertFalse(text.contains(banned), text) }
    }

    func testAnOutageStillGoingIsMeasuredToNow() {
        let samples = hourly(until: monday) + [
            Sample(date: monday.addingTimeInterval(-20.0 * 60), status: 0, milliseconds: 0),
            Sample(date: monday.addingTimeInterval(-19.5 * 60), status: 0, milliseconds: 0),
        ]
        let found = Stats.outages(samples, now: monday)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.ongoing, true)
        XCTAssertEqual(found.first?.length, 20.0 * 60)

        let entry = watched("a.com")
        let summary = WeekSummary.make(entries: [entry], samples: [entry.site.id: samples], events: [], now: monday)
        XCTAssertEqual(summary?.text(now: monday), "Last week: 1 site, 98.8% up, 1 outage (a.com, 20 minutes).")
    }

    func testOutagesAreMeasuredLikeTheBackAfterMessage() {
        let samples = hourly(until: monday, downFrom: 50.5 * 3600, lasting: 12.0 * 60)
        let found = Stats.outages(samples, now: monday)
        XCTAssertEqual(found.map(\.length), [12.0 * 60])
        XCTAssertEqual(found.first?.ongoing, false)
        XCTAssertTrue(Stats.outages(hourly(until: monday), now: monday).isEmpty)
        // One that ended before the window opened is not this week's.
        XCTAssertTrue(Stats.outages(samples, now: monday.addingTimeInterval(6 * 86_400), window: 86_400).isEmpty)
    }

    func testNoSitesMeansNoSummary() {
        XCTAssertNil(WeekSummary.make(entries: [], samples: [:], events: [], now: monday))
    }

    func testTooFewChecksMeansNoSummary() {
        // The Mac was off all week and has pulsed once since waking: one answer is not a week.
        let entry = watched("a.com")
        let once = [Sample(date: monday.addingTimeInterval(-60), status: 200, milliseconds: 200)]
        XCTAssertNil(WeekSummary.make(entries: [entry], samples: [entry.site.id: once], events: [], now: monday))
        XCTAssertNil(WeekSummary.make(entries: [entry], samples: [:], events: [], now: monday))
        // A day of checks is enough.
        let day = Array(hourly(until: monday).suffix(24))
        XCTAssertNotNil(WeekSummary.make(entries: [entry], samples: [entry.site.id: day], events: [], now: monday))
    }

    func testTheSummaryIsKeptWithTheLibrary() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var library = Library()
        library.summary = WeekSummary(date: monday, sites: 6, uptime: 0.999, outages: 1,
                                      longest: WeekSummary.LongestOutage(host: "acme-rockets.com", seconds: 720),
                                      certificates: [WeekSummary.Certificate(host: "harbour-coffee.co", expiry: monday.addingTimeInterval(9.5 * 86_400))],
                                      scoreDrops: 1)
        library.weekHandled = monday
        library.settings.weeklySummary = false
        Store(directory: directory).save(library)
        XCTAssertEqual(Store(directory: directory).loadLibrary(), library)
    }

    func testALibraryFromBeforeTheSummaryStillReads() throws {
        // Written by 0.1.1: no summary, no weekHandled, no weeklySummary setting. Losing the sites here would be unforgivable.
        let old = """
        {"entries":[{"site":{"added":1800000000,"host":"acme-rockets.com","id":"0B1E5C6E-4C0B-4B4E-9C39-6D3B6B0A2F11","url":"https://acme-rockets.com/"},\
        "state":{"blockers":0,"certificateStage":0,"failures":0,"homeNoindex":false,"isDown":false,"robotsBlocked":false,"slow":false,"slowStreak":0}}],\
        "events":[],"settings":{"auditHours":24,"notifications":false,"pulseMinutes":15}}
        """
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: directory.appendingPathComponent("library.json"))
        let library = Store(directory: directory).loadLibrary()
        XCTAssertEqual(library.entries.map(\.site.host), ["acme-rockets.com"])
        XCTAssertEqual(library.settings.pulseMinutes, 15)
        XCTAssertEqual(library.settings.auditHours, 24)
        XCTAssertFalse(library.settings.notifications)
        XCTAssertTrue(library.settings.weeklySummary, "on unless it was turned off")
        XCTAssertNil(library.summary)
        XCTAssertNil(library.weekHandled)
    }
}

// MARK: When the summary is due

final class WeeklyTests: XCTestCase {
    private let utc = calendar()

    func testTheMomentIsMondayAtNineLocalTime() {
        XCTAssertEqual(Weekly.moment(onOrBefore: monday, calendar: utc), monday, "9:00 itself counts")
        XCTAssertEqual(Weekly.moment(onOrBefore: monday.addingTimeInterval(-1), calendar: utc), monday.addingTimeInterval(-week))
        XCTAssertEqual(Weekly.moment(onOrBefore: date(2027, 1, 20, 23, 30), calendar: utc), monday)
        XCTAssertEqual(Weekly.moment(onOrBefore: date(2027, 1, 24, 23, 59), calendar: utc), monday, "Sunday night still belongs to that Monday")

        // Nine in the morning where the Mac is, not in Greenwich.
        let newYork = calendar("America/New_York")
        let there = Weekly.moment(onOrBefore: date(2027, 1, 20, 12), calendar: newYork)
        XCTAssertEqual(there, date(2027, 1, 18, 9, in: "America/New_York"))
        XCTAssertEqual(there, monday.addingTimeInterval(5 * 3600))
    }

    func testDueOnceTheMomentHasPassed() {
        XCTAssertNil(Weekly.due(handled: monday.addingTimeInterval(-week), now: monday.addingTimeInterval(-60), calendar: utc), "8:59 is too early")
        XCTAssertEqual(Weekly.due(handled: monday.addingTimeInterval(-week), now: monday, calendar: utc), monday)
        XCTAssertEqual(Weekly.due(handled: monday.addingTimeInterval(-week), now: monday.addingTimeInterval(40), calendar: utc), monday)
        XCTAssertEqual(Weekly.due(handled: nil, now: date(2027, 1, 20, 15), calendar: utc), monday, "never dealt with anything")
    }

    func testNeverTwiceForTheSameWeek() {
        // Every check for the rest of the week, a quarter of an hour apart, finds nothing owed.
        var now = monday
        while now < monday.addingTimeInterval(week - 1) {
            XCTAssertNil(Weekly.due(handled: monday, now: now, calendar: utc))
            now += 900
        }
        XCTAssertEqual(Weekly.due(handled: monday, now: monday.addingTimeInterval(week), calendar: utc), monday.addingTimeInterval(week))
    }

    func testAsleepThroughMondayItComesAtTheFirstChanceAfter() {
        let lastWeek = monday.addingTimeInterval(-week)
        // The lid was shut from Sunday night to Wednesday afternoon.
        let wednesday = date(2027, 1, 20, 14, 12)
        XCTAssertEqual(Weekly.due(handled: lastWeek, now: wednesday, calendar: utc), monday)
        XCTAssertNil(Weekly.due(handled: monday, now: wednesday.addingTimeInterval(15), calendar: utc))
    }

    func testAsleepForWeeksOwesOneSummaryNotOnePerWeek() {
        let longAgo = monday.addingTimeInterval(-5 * week)
        let waking = monday.addingTimeInterval(2 * 86_400)
        let owed = Weekly.due(handled: longAgo, now: waking, calendar: utc)
        XCTAssertEqual(owed, monday, "only the latest Monday")
        XCTAssertNil(Weekly.due(handled: owed, now: waking.addingTimeInterval(15), calendar: utc))
    }

    func testAClockSetBackDoesNotSendAgain() {
        // Sent on Monday, then the clock is put back to Sunday, or to the Monday before.
        XCTAssertNil(Weekly.due(handled: monday, now: monday.addingTimeInterval(-86_400), calendar: utc))
        XCTAssertNil(Weekly.due(handled: monday, now: monday.addingTimeInterval(-week + 60), calendar: utc))
        XCTAssertEqual(Weekly.settled(handled: monday, now: monday.addingTimeInterval(-86_400), calendar: utc), monday, "a small step back changes nothing")
        // Time then runs forward through Monday 9:00 a second time: still nothing.
        XCTAssertNil(Weekly.due(handled: monday, now: monday.addingTimeInterval(30), calendar: utc))
    }

    func testAClockOnceSetFarAheadDoesNotSilenceTheSummaryForGood() {
        // A summary went out while the clock said March. Back in January, that record would never come round.
        let march = monday.addingTimeInterval(8 * week)
        let tuesday = monday.addingTimeInterval(86_400)
        XCTAssertNil(Weekly.due(handled: march, now: tuesday, calendar: utc))
        let settled = Weekly.settled(handled: march, now: tuesday, calendar: utc)
        XCTAssertEqual(settled, monday, "this week counts as dealt with")
        XCTAssertNil(Weekly.due(handled: settled, now: tuesday, calendar: utc))
        XCTAssertEqual(Weekly.due(handled: settled, now: monday.addingTimeInterval(week + 5), calendar: utc), monday.addingTimeInterval(week))
    }

    func testAClockSetForwardSendsOneAndThenWaits() {
        let nextMonth = monday.addingTimeInterval(4 * week + 3 * 86_400)
        let owed = Weekly.due(handled: monday, now: nextMonth, calendar: utc)
        XCTAssertEqual(owed, monday.addingTimeInterval(4 * week))
        XCTAssertNil(Weekly.due(handled: owed, now: nextMonth.addingTimeInterval(15), calendar: utc))
    }

    func testMovingTimeZoneIsNotANewWeek() {
        // Monday 9:00 in Auckland, then the same Monday 9:00 comes round again in Honolulu, 23 hours later.
        let auckland = date(2027, 1, 18, 9, in: "Pacific/Auckland")
        let honolulu = calendar("Pacific/Honolulu")
        let there = date(2027, 1, 18, 9, 30, in: "Pacific/Honolulu")
        XCTAssertGreaterThan(there, auckland)
        XCTAssertLessThan(there.timeIntervalSince(auckland), 2 * 86_400)
        XCTAssertNil(Weekly.due(handled: auckland, now: there, calendar: honolulu))
        XCTAssertEqual(Weekly.due(handled: auckland, now: there.addingTimeInterval(week), calendar: honolulu), date(2027, 1, 25, 9, in: "Pacific/Honolulu"))
    }
}

// MARK: The weekly summary, end to end

final class WeeklyWatcherTests: XCTestCase {
    private var directory: URL!
    private var pulser: StubPulser!
    private var clock: TestClock!

    override func setUp() {
        directory = scratch()
        pulser = StubPulser()
        clock = TestClock(start)        // Friday 15 January 2027, 8:00 UTC
        pulser.queue("acme-rockets.com", up)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func watcher() -> Watcher {
        let clock = self.clock!
        return Watcher(store: Store(directory: directory), pulser: pulser, auditor: StubAuditor(), domains: StubDomains(), sideDoor: StubSideDoor(), clock: { clock.now }, calendar: calendar())
    }

    /// Lets time pass to `end`, pulsing once an hour on the way and once on arriving.
    private func run(_ watcher: Watcher, until end: Date) async {
        while clock.now < end {
            clock.advance(min(3600, end.timeIntervalSince(clock.now)))
            _ = await watcher.pulseDue()
        }
    }

    func testSentOnceOnMondayAndKept() async {
        let watcher = watcher()
        _ = await watcher.add("acme-rockets.com")
        var sent = await watcher.weeklySummaryIfDue()
        XCTAssertNil(sent, "a site added on Friday has no week behind it at the Monday before")

        await run(watcher, until: monday.addingTimeInterval(-300))
        sent = await watcher.weeklySummaryIfDue()
        XCTAssertNil(sent, "five to nine is too early")

        await run(watcher, until: monday)
        sent = await watcher.weeklySummaryIfDue()
        XCTAssertEqual(sent?.text(now: clock.now), "Last week: acme-rockets.com stayed up.")

        sent = await watcher.weeklySummaryIfDue()
        XCTAssertNil(sent, "the same check a moment later")
        await run(watcher, until: monday.addingTimeInterval(3 * 86_400))
        sent = await watcher.weeklySummaryIfDue()
        XCTAssertNil(sent, "the rest of the week")

        // Quit and opened again: still dealt with, and the summary is still there for the panel.
        let reopened = self.watcher()
        sent = await reopened.weeklySummaryIfDue()
        XCTAssertNil(sent)
        let kept = await reopened.summary
        XCTAssertEqual(kept?.text(now: clock.now), "Last week: acme-rockets.com stayed up.")

        await run(reopened, until: monday.addingTimeInterval(week))
        sent = await reopened.weeklySummaryIfDue()
        XCTAssertNotNil(sent, "next Monday brings the next one")
    }

    func testAsleepOverMondayItIsSentOnWaking() async {
        let watcher = watcher()
        _ = await watcher.add("acme-rockets.com")
        _ = await watcher.weeklySummaryIfDue()
        await run(watcher, until: monday.addingTimeInterval(-86_400))       // Sunday morning, then the lid is shut

        clock.advance(3 * 86_400 + 4000)                                    // Wednesday
        _ = await watcher.pulseDue()
        var sent = await watcher.weeklySummaryIfDue()
        XCTAssertEqual(sent?.sites, 1)
        sent = await watcher.weeklySummaryIfDue()
        XCTAssertNil(sent)
    }

    func testSwitchedOffNothingIsSentAndTurningItOnDoesNotSendLate() async {
        let watcher = watcher()
        _ = await watcher.add("acme-rockets.com")
        var settings = WatchSettings()
        settings.weeklySummary = false
        await watcher.set(settings)

        await run(watcher, until: monday.addingTimeInterval(600))
        var sent = await watcher.weeklySummaryIfDue()
        XCTAssertNil(sent)
        var kept = await watcher.summary
        XCTAssertNil(kept)

        settings.weeklySummary = true
        await watcher.set(settings)
        sent = await watcher.weeklySummaryIfDue()
        XCTAssertNil(sent, "Monday has been and gone; the first summary is next Monday's")
        await run(watcher, until: monday.addingTimeInterval(week))
        sent = await watcher.weeklySummaryIfDue()
        XCTAssertNotNil(sent)
        kept = await watcher.summary
        XCTAssertEqual(kept, sent)
    }

    func testWithNoSitesNothingIsSent() async {
        let watcher = watcher()
        clock.advance(4 * 86_400)
        var sent = await watcher.weeklySummaryIfDue()
        XCTAssertNil(sent)

        // A site added on Tuesday does not get last week's summary a minute later.
        _ = await watcher.add("acme-rockets.com")
        await run(watcher, until: clock.now.addingTimeInterval(86_400 + 3600))
        sent = await watcher.weeklySummaryIfDue()
        XCTAssertNil(sent)
    }
}

// MARK: Uptime strip

final class StripTests: XCTestCase {
    private let utc = calendar()
    /// Friday 15 January 2027, 8:00 UTC: two hours into the 6:00 to 12:00 stretch.
    private let now = start

    private func sample(hoursAgo: Double, ok: Bool = true) -> Sample {
        Sample(date: now.addingTimeInterval(-hoursAgo * 3600), status: ok ? 200 : 0, milliseconds: ok ? 200 : 0)
    }

    func testTwentyEightCellsFourADayOnTheClock() {
        let cells = Stats.strip([], now: now, calendar: utc)
        XCTAssertEqual(cells.count, 28)
        XCTAssertEqual(cells.last?.start, date(2027, 1, 15, 6))
        XCTAssertEqual(cells.last?.end, date(2027, 1, 15, 12))
        XCTAssertEqual(cells.first?.start, date(2027, 1, 8, 12))
        for (before, after) in zip(cells, cells.dropFirst()) {
            XCTAssertEqual(before.end, after.start)
            XCTAssertEqual(after.start.timeIntervalSince(before.start), 6.0 * 3600)
        }
        XCTAssertTrue(cells.allSatisfy { $0.state == .empty })

        // The stretches follow the local clock, not Greenwich: 8:00 UTC is 13:30 in Kolkata, in the 12:00 to 18:00 stretch.
        let kolkata = Stats.strip([], now: now, calendar: calendar("Asia/Kolkata"))
        XCTAssertEqual(kolkata.last?.start, date(2027, 1, 15, 12, in: "Asia/Kolkata"))
    }

    func testUpDownAndGaps() {
        let samples = [
            sample(hoursAgo: 170),                      // before the strip begins
            sample(hoursAgo: 50),                       // cell 19: up
            sample(hoursAgo: 49.9, ok: false),          // one dropped request in an otherwise good stretch
            sample(hoursAgo: 49.8),
            sample(hoursAgo: 25),                       // cell 23
            sample(hoursAgo: 24.5, ok: false),
            sample(hoursAgo: 24.4, ok: false),          // twice in a row: down
            sample(hoursAgo: 24.2),
            sample(hoursAgo: 1),                        // cell 27, the stretch under way
            sample(hoursAgo: -1),                       // the future, after a clock change
        ]
        let cells = Stats.strip(samples, now: now, calendar: utc)
        XCTAssertEqual(cells[19].state, .up, "one dropped request is not down")
        XCTAssertEqual(cells[23].state, .down)
        XCTAssertEqual(cells[27].state, .up)
        XCTAssertEqual(cells.filter { $0.state == .empty }.count, 25, "nothing was measured, so nothing is claimed")
        XCTAssertEqual(cells[0].state, .empty)
    }

    func testAnOutageAcrossTwoStretchesMarksBoth() {
        // Down from 5:50 to 6:10, either side of the 6:00 line.
        let samples = [
            sample(hoursAgo: 3),
            sample(hoursAgo: 2.0 + 10.0 / 60, ok: false),
            sample(hoursAgo: 1.0 + 50.0 / 60, ok: false),
            sample(hoursAgo: 1.5),
        ]
        let cells = Stats.strip(samples, now: now, calendar: utc)
        XCTAssertEqual(cells[26].state, .down)
        XCTAssertEqual(cells[27].state, .down)
    }

    func testAPulseOnTheLineBelongsToTheStretchItStarts() {
        let onTheLine = Sample(date: date(2027, 1, 15, 0), status: 200, milliseconds: 200)
        let cells = Stats.strip([onTheLine], now: now, calendar: utc)
        XCTAssertEqual(cells[26].state, .up)
        XCTAssertEqual(cells[25].state, .empty)
    }

    func testDownStaysDownWhateverElseTheStretchHolds() {
        let samples = [sample(hoursAgo: 1.5, ok: false), sample(hoursAgo: 1.4, ok: false), sample(hoursAgo: 1), sample(hoursAgo: 0.5)]
        XCTAssertEqual(Stats.strip(samples, now: now, calendar: utc)[27].state, .down)
    }

    func testOtherShapes() {
        XCTAssertEqual(Stats.strip([], now: now, calendar: utc, days: 2, perDay: 2).count, 4)
        XCTAssertTrue(Stats.strip([], now: now, calendar: utc, days: 0).isEmpty)
    }

    func testSpokenSummary() {
        func cells(_ states: [StripCell.State]) -> [StripCell] {
            states.map { StripCell(state: $0, start: now, end: now) }
        }
        let up = [StripCell.State](repeating: .up, count: 28)
        XCTAssertEqual(Stats.stripSummary(cells(up)), "Up through all of the last 7 days.")
        XCTAssertEqual(Stats.stripSummary(cells([.empty, .empty] + up.dropFirst(2))), "Up whenever it was checked in the last 7 days. Not checked during 2.")
        XCTAssertEqual(Stats.stripSummary(cells([.down, .down, .empty] + up.dropFirst(3))),
                       "Down during 2 of the 28 six hour stretches in the last 7 days. Not checked during 1.")
        XCTAssertEqual(Stats.stripSummary(cells([.down] + up.dropFirst(1))), "Down during 1 of the 28 six hour stretches in the last 7 days.")
        XCTAssertEqual(Stats.stripSummary(cells([StripCell.State](repeating: .empty, count: 28))), "No checks in the last 7 days.")
        XCTAssertEqual(StripCell(state: .down, start: now, end: now).words, "down for some of it")
    }

    func testTheRowCarriesItsStrip() {
        var state = SiteState()
        state.lastPulse = now
        let row = SiteSummary.make(Entry(site: site, state: state), samples: [sample(hoursAgo: 1)], events: [], now: now, calendar: utc)
        XCTAssertEqual(row.strip.count, 28)
        XCTAssertEqual(row.strip.last?.state, .up)
    }
}

// MARK: Opening the report in Launchcheck

/// Says an app is there, or is not, and remembers what it was asked.
final class StubSchemes: SchemeChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let installed: Bool
    private var seen: [URL] = []

    init(installed: Bool) { self.installed = installed }

    var asked: [URL] { lock.withLock { seen } }

    func hasApp(for url: URL) -> Bool {
        lock.withLock {
            seen.append(url)
            return installed
        }
    }
}

final class ReportLinkTests: XCTestCase {
    func testTheLinkIsExactlyTheFormLaunchcheckExpects() {
        XCTAssertEqual(ReportLink.url(for: site)?.absoluteString, "launchcheck://open?site=acme-rockets.com")
        let mixed = Site(url: "https://WWW.Example.com/", host: "www.example.com", added: start)
        XCTAssertEqual(ReportLink.url(for: mixed)?.absoluteString, "launchcheck://open?site=www.example.com")
        let local = Site(url: "http://localhost:8080/", host: "localhost", added: start)
        XCTAssertEqual(ReportLink.url(for: local)?.absoluteString, "launchcheck://open?site=localhost:8080")
        XCTAssertNil(ReportLink.url(for: Site(url: "", host: "", added: start)))
    }

    func testOfferedOnlyWhenSomeAppOpensTheScheme() {
        let present = StubSchemes(installed: true)
        XCTAssertTrue(ReportLink.available(present))
        XCTAssertEqual(present.asked.map(\.scheme), ["launchcheck"], "it asks about a launchcheck link and nothing else")

        let absent = StubSchemes(installed: false)
        XCTAssertFalse(ReportLink.available(absent))
        XCTAssertEqual(absent.asked.count, 1)
    }
}
