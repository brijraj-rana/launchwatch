import LaunchcheckCore
import XCTest
@testable import LaunchwatchCore

// MARK: Stubs

/// Answers from a script instead of the network.
final class StubPulser: Pulser, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [PulseResult]] = [:]
    private(set) var asked: [String] = []

    /// Queues answers for a host. The last one repeats once the queue runs out.
    func queue(_ host: String, _ results: PulseResult...) {
        lock.lock()
        answers[host, default: []] += results
        lock.unlock()
    }

    func pulse(_ url: URL) async -> PulseResult {
        lock.withLock {
            let host = url.host ?? ""
            asked.append(host)
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
        return Watcher(store: Store(directory: directory), pulser: pulser, auditor: auditor, clock: { clock.now })
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
