import LaunchcheckCore
import XCTest
@testable import LaunchwatchCore

// Pausing, domain expiry, must contain, the webhook, the response chart, the diagnosis and the issue list.
// Nothing here touches the network: the registry, the side door and the pulses are all scripts.

// MARK: Stubs

/// A registry that answers from a script and remembers what it was asked.
final class StubDomains: DomainLookup, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [DomainAnswer] = []
    private(set) var asked: [String] = []

    func queue(_ answers: DomainAnswer...) {
        lock.withLock { self.answers += answers }
    }

    func expiry(of domain: String) async -> DomainAnswer {
        lock.withLock {
            asked.append(domain)
            guard !answers.isEmpty else { return .unknown }
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }
}

/// Other addresses on a server: which answer, and with what.
final class StubSideDoor: SideDoorAsking, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: Int] = [:]
    private(set) var asked: [String] = []

    func answer(_ path: String, _ status: Int) {
        lock.withLock { statuses[path] = status }
    }

    func status(of url: URL) async -> Int? {
        lock.withLock {
            asked.append(url.path)
            return statuses[url.path]
        }
    }
}

// MARK: Fixtures

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let site = Site(url: "https://acme-rockets.com/", host: "acme-rockets.com", added: start)
private let shop = Site(url: "https://lumen-bikes.com/", host: "lumen-bikes.com", added: start, mustContain: "Add to cart")
private let up = PulseResult(status: 200, milliseconds: 200)
private let refused = PulseResult(status: 0, error: "the server refused the connection", failure: .refused)
private let day: TimeInterval = 86_400

private func utc() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_GB")
    return calendar
}

private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    utc().date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("launchwatch-tests-\(UUID().uuidString)", isDirectory: true)
}

private func samples(_ statuses: [Int], every seconds: TimeInterval = 300, from first: Date = start) -> [Sample] {
    statuses.enumerated().map { Sample(date: first.addingTimeInterval(Double($0.offset) * seconds), status: $0.element, milliseconds: 200) }
}

/// Runs pulses through the detector one after another, as the watcher would.
private func fold(_ results: [PulseResult], on site: Site, from state: SiteState = SiteState()) -> (state: SiteState, events: [SiteEvent]) {
    var state = state
    var events: [SiteEvent] = []
    var history: [Sample] = []
    var now = start
    for result in results {
        let folded = Detector.afterPulse(site: site, state: state, result: result, history: history, now: now)
        state = folded.state
        events += folded.events
        history.append(Sample(date: now, status: result.status, milliseconds: result.milliseconds, phases: result.phases))
        now += 300
    }
    return (state, events)
}

private func page(_ html: String) -> PulseResult {
    PulseResult(status: 200, milliseconds: 200, body: html, finalURL: "https://lumen-bikes.com/")
}

// MARK: Pausing

final class PauseTests: XCTestCase {
    private let settings = WatchSettings()

    private func checked(_ ago: TimeInterval, now: Date) -> SiteState {
        var state = SiteState()
        state.lastPulse = now.addingTimeInterval(-ago)
        return state
    }

    func testTheThreeLengths() {
        let now = at(2027, 1, 20, 22, 30)
        XCTAssertEqual(PauseLength.hour.end(from: now, calendar: utc()), at(2027, 1, 20, 23, 30))
        XCTAssertEqual(PauseLength.tomorrow.end(from: now, calendar: utc()), at(2027, 1, 21, 9), "morning, not midnight")
        XCTAssertNil(PauseLength.untilResumed.end(from: now, calendar: utc()))
        // Asked just after midnight, tomorrow is still the next day.
        XCTAssertEqual(PauseLength.tomorrow.end(from: at(2027, 1, 20, 0, 5), calendar: utc()), at(2027, 1, 21, 9))
    }

    func testAPausedSiteIsNeverDue() {
        let now = start
        let state = Pausing.paused(checked(3600, now: now), until: now.addingTimeInterval(3600), now: now)
        XCTAssertTrue(Pausing.isPaused(state, now: now))
        XCTAssertFalse(Scheduler.pulseDue(state, settings: settings, now: now.addingTimeInterval(1800)))
        XCTAssertFalse(Scheduler.auditDue(state, settings: settings, now: now.addingTimeInterval(1800)))
        XCTAssertFalse(Scheduler.domainDue(Entry(site: site, state: state), settings: settings, now: now.addingTimeInterval(1800)))
    }

    func testItIsDueAgainTheMomentThePauseEnds() {
        let now = start
        let state = Pausing.paused(checked(60, now: now), until: now.addingTimeInterval(3600), now: now)
        XCTAssertFalse(Scheduler.pulseDue(state, settings: settings, now: now.addingTimeInterval(3599)))
        XCTAssertTrue(Scheduler.pulseDue(state, settings: settings, now: now.addingTimeInterval(3600)))
        XCTAssertFalse(Pausing.isPaused(state, now: now.addingTimeInterval(3600)))
    }

    func testUntilResumedWaitsForever() {
        let state = Pausing.paused(checked(60, now: start), until: nil, now: start)
        XCTAssertFalse(Scheduler.pulseDue(state, settings: settings, now: start.addingTimeInterval(400 * day)))
        let resumed = Pausing.resumed(state, now: start.addingTimeInterval(2 * day))
        XCTAssertTrue(Scheduler.pulseDue(resumed, settings: settings, now: start.addingTimeInterval(2 * day)))
        XCTAssertEqual(resumed.pauses, [Pause(since: start, until: start.addingTimeInterval(2 * day))])
    }

    func testPausingForgetsWhatWasGoingWrong() {
        var state = checked(60, now: start)
        state.failures = 3
        state.isDown = true
        state.failingSince = start.addingTimeInterval(-900)
        state.slow = true
        state.missingPhrase = "Add to cart"
        state.phraseMisses = 4
        let paused = Pausing.paused(state, until: nil, now: start)
        XCTAssertFalse(paused.isDown)
        XCTAssertEqual(paused.failures, 0)
        XCTAssertNil(paused.failingSince)
        XCTAssertFalse(paused.slow)
        XCTAssertNil(paused.missingPhrase)
        // So coming back up after the pause is not announced as a recovery.
        let after = Detector.afterPulse(site: site, state: Pausing.resumed(paused, now: start.addingTimeInterval(3600)), result: up, history: [],
                                        now: start.addingTimeInterval(3600))
        XCTAssertTrue(after.events.isEmpty)
    }

    func testSettlingEndsATimedPauseAtItsOwnEndAndDropsOldOnes() {
        var state = Pausing.paused(SiteState(), until: start.addingTimeInterval(3600), now: start)
        state.pauses = [Pause(since: start.addingTimeInterval(-20 * day), until: start.addingTimeInterval(-19 * day))]
        let settled = Pausing.settled(state, now: start.addingTimeInterval(5 * 3600))
        XCTAssertNil(settled.pause)
        XCTAssertEqual(settled.pauses, [Pause(since: start, until: start.addingTimeInterval(3600))])
        // Still under way: nothing changes.
        let early = Pausing.paused(SiteState(), until: start.addingTimeInterval(3600), now: start)
        XCTAssertEqual(Pausing.settled(early, now: start.addingTimeInterval(60)), early)
    }

    func testNextPulseSkipsPausedSitesAndWaitsForATimedOne() {
        let now = start
        let resting = Entry(site: site, state: Pausing.paused(checked(60, now: now), until: now.addingTimeInterval(3600), now: now))
        let forever = Entry(site: shop, state: Pausing.paused(checked(60, now: now), until: nil, now: now))
        XCTAssertEqual(Scheduler.nextPulse([resting, forever], settings: settings, now: now), now.addingTimeInterval(3600))
        XCTAssertNil(Scheduler.nextPulse([forever], settings: settings, now: now))
        XCTAssertEqual(Scheduler.pulsesDue([resting, forever], settings: settings, now: now.addingTimeInterval(1800)), [])
    }

    func testHealthAndWords() {
        let now = at(2027, 1, 20, 13, 10)
        let today = Pausing.paused(checked(60, now: now), until: at(2027, 1, 20, 14), now: now)
        XCTAssertEqual(Health.of(today, now: now, calendar: utc()), Health(condition: .paused, note: "Paused until 14:00"))
        // Another day is named. How the hour is written is the locale's business, so only its digits are checked.
        let tomorrow = Words.paused(until: at(2027, 1, 21, 9), now: now, calendar: utc())
        XCTAssertTrue(tomorrow.hasPrefix("Paused until Thu "), tomorrow)
        XCTAssertTrue(tomorrow.hasSuffix("9:00"), tomorrow)
        XCTAssertEqual(Words.paused(until: nil, now: now, calendar: utc()), "Paused until resumed")
        XCTAssertFalse(Health.of(today, now: now, calendar: utc()).needsAttention)

        // Even a site that was down, with an expired certificate, raises nothing while paused.
        var broken = checked(60, now: now)
        broken.isDown = true
        broken.certificateStage = .expired
        XCTAssertEqual(Health.of(Pausing.paused(broken, until: nil, now: now), now: now, calendar: utc()).condition, .paused)
    }

    func testAPausedSiteIsLeftOutOfTheHeadlineAndSortsLast() {
        let now = start
        func summary(_ host: String, _ change: (inout SiteState) -> Void = { _ in }) -> SiteSummary {
            var state = checked(60, now: now)
            change(&state)
            return SiteSummary.make(Entry(site: Site(url: "https://\(host)/", host: host, added: now), state: state), samples: [], events: [], now: now, calendar: utc())
        }
        let paused = summary("a.example") { $0 = Pausing.paused($0, until: nil, now: now) }
        let fine = summary("b.example")
        let down = summary("c.example") { $0.isDown = true; $0.failingSince = now }
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(Verdict.line([paused, fine, fine], offline: false), "All 2 sites are fine")
        XCTAssertEqual(Verdict.line([paused, fine], offline: false), "b.example is fine")
        XCTAssertEqual(Verdict.line([paused], offline: false), "a.example is paused")
        XCTAssertEqual(Verdict.line([paused, paused], offline: false), "All 2 sites are paused")
        XCTAssertEqual(Verdict.line([paused, down], offline: false), "c.example is down")
        XCTAssertEqual(SiteSummary.sorted([paused, fine, down]).map(\.site.host), ["c.example", "b.example", "a.example"])
        XCTAssertEqual(paused.spoken, "a.example, Paused until resumed")
    }

    // Stats

    func testPausedTimeIsLeftOutOfUptime() {
        // Ten checks: the middle four fell inside a pause and failed. They are not counted.
        var all = samples([200, 200, 200, 0, 0, 0, 0, 200, 200, 200])
        let now = all.last!.date
        let pause = Pause(since: all[3].date, until: all[7].date)
        XCTAssertEqual(Stats.uptime(all, now: now)!, 0.6, accuracy: 0.001)
        XCTAssertEqual(Stats.uptime(all, now: now, pauses: [pause]), 1)
        // With nothing checked during the pause, which is what really happens, it is simply absent.
        all.removeSubrange(3..<7)
        XCTAssertEqual(Stats.uptime(all, now: now, pauses: [pause]), 1)
    }

    func testAnOutageEndsWhereAPauseBegins() {
        // Down for ten minutes, then paused for a day, then fine. The outage is ten minutes, not a day.
        let failing = samples([200, 0, 0, 0])
        let pauseStart = failing.last!.date.addingTimeInterval(120)
        let back = Sample(date: pauseStart.addingTimeInterval(day), status: 200, milliseconds: 200)
        let now = back.date.addingTimeInterval(60)
        let whole = Stats.outages(failing + [back], now: now)
        XCTAssertEqual(whole.first?.length ?? 0, day + 720, accuracy: 1)
        let cut = Stats.outages(failing + [back], now: now, pauses: [Pause(since: pauseStart, until: back.date)])
        XCTAssertEqual(cut, [Outage(start: failing[1].date, end: pauseStart, ongoing: false)])
        // Paused and still paused: the outage is over, not ongoing.
        let still = Stats.outages(failing, now: now, pauses: [Pause(since: pauseStart, until: now)])
        XCTAssertEqual(still, [Outage(start: failing[1].date, end: pauseStart, ongoing: false)])
    }

    func testOneFailureEachSideOfAPauseIsNotAnOutage() {
        let before = Sample(date: start, status: 0, milliseconds: 0)
        let after = Sample(date: start.addingTimeInterval(7200), status: 0, milliseconds: 0)
        let pause = Pause(since: start.addingTimeInterval(60), until: start.addingTimeInterval(7000))
        XCTAssertEqual(Stats.downFlags([before, after]), [true, true])
        XCTAssertEqual(Stats.downFlags([before, after], pauses: [pause]), [false, false])
    }

    func testTheStripShowsPausedStretches() {
        let now = at(2027, 1, 20, 12, 30)
        let pause = Pause(since: at(2027, 1, 19, 1), until: at(2027, 1, 19, 13))
        let checks = [Sample(date: at(2027, 1, 18, 20), status: 200, milliseconds: 200), Sample(date: at(2027, 1, 19, 14), status: 200, milliseconds: 200)]
        let strip = Stats.strip(checks, now: now, calendar: utc(), pauses: [pause])
        func cell(_ day: Int, _ hour: Int) -> StripCell.State? { strip.first { $0.start == at(2027, 1, day, hour) }?.state }
        XCTAssertEqual(cell(18, 18), .up)
        XCTAssertEqual(cell(19, 0), .paused)
        XCTAssertEqual(cell(19, 6), .paused)
        XCTAssertEqual(cell(19, 12), .up, "a stretch with a check in it is judged by the check")
        XCTAssertEqual(cell(19, 18), .empty, "after the pause, unchecked is just unchecked")
        XCTAssertEqual(StripCell(state: .paused, start: now, end: now).words, "paused")
    }

    func testTheWeeklySummaryLeavesPausedTimeOut() {
        let now = start.addingTimeInterval(6 * day)
        var checks: [Sample] = []
        for hour in 0..<(6 * 24) { checks.append(Sample(date: start.addingTimeInterval(Double(hour) * 3600), status: hour == 50 || hour == 51 ? 0 : 200, milliseconds: 200)) }
        var state = SiteState()
        state.lastPulse = now
        // The two failed checks were followed at once by a pause that lasted a day.
        checks.removeSubrange(52..<76)
        state.pauses = [Pause(since: start.addingTimeInterval(51.5 * 3600), until: start.addingTimeInterval(76 * 3600))]
        let summary = WeekSummary.make(entries: [Entry(site: site, state: state)], samples: [site.id: checks], events: [], now: now)
        XCTAssertEqual(summary?.outages, 1)
        XCTAssertEqual(summary?.longest?.seconds ?? 0, 1.5 * 3600, accuracy: 1)
    }
}

// MARK: Pausing, through the watcher

final class PauseWatcherTests: XCTestCase {
    private var directory: URL!
    private var pulser: StubPulser!
    private var clock: TestClock!

    override func setUp() {
        directory = scratch()
        pulser = StubPulser()
        clock = TestClock(at(2027, 1, 20, 13))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func watcher() -> Watcher {
        let clock = self.clock!
        return Watcher(store: Store(directory: directory), pulser: pulser, auditor: StubAuditor(), domains: StubDomains(), sideDoor: StubSideDoor(),
                       clock: { clock.now }, calendar: utc())
    }

    func testAPausedSiteIsNotCheckedAndRaisesNothing() async {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", up, refused)
        guard case .added(let added) = await watcher.add("acme-rockets.com") else { return XCTFail("not added") }
        await watcher.pause(added.id, for: .hour)
        let asked = pulser.asked.count

        clock.advance(1800)
        let due = await watcher.pulsesDue()
        XCTAssertEqual(due, [])
        // Even asked for by name, as "check every site now" would.
        let outcome = await watcher.pulse([added.id])
        XCTAssertEqual(outcome.pulsed, 0)
        XCTAssertEqual(pulser.asked.count, asked, "no request went out")
        let events = await watcher.audit(added.id)
        XCTAssertTrue(events.isEmpty)
        let summary = await watcher.summaries().first
        XCTAssertEqual(summary?.health.note, "Paused until 14:00")
    }

    func testChecksStartAgainWhenThePauseEndsAndItSurvivesARestart() async {
        var watcher = watcher()
        pulser.queue("acme-rockets.com", up)
        guard case .added(let added) = await watcher.add("acme-rockets.com") else { return XCTFail("not added") }
        await watcher.pause(added.id, for: .tomorrow)

        watcher = self.watcher()                      // the app was quit and opened again
        clock.advance(10 * 3600)
        var due = await watcher.pulsesDue()
        XCTAssertEqual(due, [], "23:00, still paused")
        clock.advance(10 * 3600)
        due = await watcher.pulsesDue()
        XCTAssertEqual(due, [added.id], "9:00 the next morning")
        let entry = await watcher.entries.first
        XCTAssertNil(entry?.state.pause)
        XCTAssertEqual(entry?.state.pauses, [Pause(since: at(2027, 1, 20, 13), until: at(2027, 1, 21, 9))])
    }

    func testResumingByHand() async {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", up)
        guard case .added(let added) = await watcher.add("acme-rockets.com") else { return XCTFail("not added") }
        await watcher.pause(added.id, for: .untilResumed)
        clock.advance(3 * day)
        await watcher.resume(added.id)
        let outcome = await watcher.pulse([added.id])
        XCTAssertEqual(outcome.pulsed, 1)
        XCTAssertTrue(outcome.events.isEmpty)
    }
}

// MARK: Domain expiry

final class DomainTests: XCTestCase {
    func testTheRegistrableDomain() {
        XCTAssertEqual(Domain.registrable("example.com"), "example.com")
        XCTAssertEqual(Domain.registrable("www.example.com"), "example.com")
        XCTAssertEqual(Domain.registrable("Shop.Staging.Example.COM."), "example.com")
        XCTAssertEqual(Domain.registrable("harbour-coffee.co"), "harbour-coffee.co")
        XCTAssertEqual(Domain.registrable("tidyhq.io"), "tidyhq.io")
    }

    func testCommonMultiPartEndings() {
        XCTAssertEqual(Domain.registrable("www.acme.co.uk"), "acme.co.uk")
        XCTAssertEqual(Domain.registrable("acme.co.uk"), "acme.co.uk")
        XCTAssertEqual(Domain.registrable("shop.acme.com.au"), "acme.com.au")
        XCTAssertEqual(Domain.registrable("a.b.acme.co.nz"), "acme.co.nz")
        XCTAssertEqual(Domain.registrable("acme.co.jp"), "acme.co.jp")
        XCTAssertEqual(Domain.registrable("www.acme.com.br"), "acme.com.br")
        XCTAssertEqual(Domain.registrable("www.acme.co.in"), "acme.co.in")
        XCTAssertEqual(Domain.registrable("www.acme.org.uk"), "acme.org.uk")
        XCTAssertEqual(Domain.registrable("www.acme.me.uk"), "acme.me.uk")
        XCTAssertEqual(Domain.registrable("www.acme.id.au"), "acme.id.au")
        // "co" and "com" are only endings under a country, and a short name is still a name.
        XCTAssertEqual(Domain.registrable("www.co.example.com"), "example.com")
        XCTAssertEqual(Domain.registrable("id.me"), "id.me")
    }

    func testAddressesWithNoDomainToAskAbout() {
        XCTAssertNil(Domain.registrable("localhost"))
        XCTAssertNil(Domain.registrable("192.168.1.20"))
        XCTAssertNil(Domain.registrable("[::1]"))
        XCTAssertNil(Domain.registrable(""))
        XCTAssertNil(Domain.registrable("example..com"))
        // Borrowed from a platform: the name above it is not the site owner's to renew.
        XCTAssertNil(Domain.registrable("acme-rockets.vercel.app"))
        XCTAssertNil(Domain.registrable("acme.github.io"))
        XCTAssertNil(Domain.registrable("shop.acme.myshopify.com"))
    }

    func testReadingTheExpiryFromRDAP() {
        // The shape a registry answers with, cut down: the events are what matter.
        let answer = """
        {"objectClassName":"domain","handle":"2336799_DOMAIN_COM-VRSN","ldhName":"ACME-ROCKETS.COM",
         "status":["client transfer prohibited"],
         "events":[{"eventAction":"registration","eventDate":"1995-08-14T04:00:00Z"},
                   {"eventAction":"expiration","eventDate":"2027-08-13T04:00:00Z"},
                   {"eventAction":"last changed","eventDate":"2026-08-14T07:01:39Z"},
                   {"eventAction":"last update of RDAP database","eventDate":"2026-11-18T10:27:05Z"}],
         "nameservers":[{"objectClassName":"nameserver","ldhName":"NS1.EXAMPLE.NET"}]}
        """
        XCTAssertEqual(RDAP.expiry(from: Data(answer.utf8)), at(2027, 8, 13, 4))
    }

    func testOtherDateShapesAndTheRegistrarsDate() {
        func events(_ json: String) -> Date? { RDAP.expiry(from: Data("{\"events\":[\(json)]}".utf8)) }
        XCTAssertEqual(events(#"{"eventAction":"expiration","eventDate":"2027-03-04T23:59:59.0Z"}"#), at(2027, 3, 4, 23, 59).addingTimeInterval(59))
        XCTAssertEqual(events(#"{"eventAction":"expiration","eventDate":"2027-03-04T12:00:00+02:00"}"#), at(2027, 3, 4, 10))
        XCTAssertEqual(events(#"{"eventAction":"Expiration","eventDate":"2027-03-04T12:00:00"}"#), at(2027, 3, 4, 12))
        XCTAssertEqual(events(#"{"eventAction":"expiration","eventDate":"2027-03-04"}"#), at(2027, 3, 4))
        // Only the registrar's date is given: better than nothing.
        XCTAssertEqual(events(#"{"eventAction":"registrar expiration","eventDate":"2027-05-01T00:00:00Z"}"#), at(2027, 5, 1))
        // Both: the registry's wins.
        XCTAssertEqual(events(#"{"eventAction":"registrar expiration","eventDate":"2027-05-01T00:00:00Z"},{"eventAction":"expiration","eventDate":"2027-06-01T00:00:00Z"}"#), at(2027, 6, 1))
    }

    func testNoAnswerIsNoDate() {
        XCTAssertNil(RDAP.expiry(from: Data()))
        XCTAssertNil(RDAP.expiry(from: Data("<html>Not Found</html>".utf8)))
        XCTAssertNil(RDAP.expiry(from: Data(#"{"errorCode":404,"title":"Not Found"}"#.utf8)))
        XCTAssertNil(RDAP.expiry(from: Data(#"{"events":[{"eventAction":"registration","eventDate":"1995-08-14T04:00:00Z"}]}"#.utf8)))
        XCTAssertNil(RDAP.expiry(from: Data(#"{"events":[{"eventAction":"expiration","eventDate":"soon"}]}"#.utf8)))
        XCTAssertNil(RDAP.expiry(from: Data(#"["events"]"#.utf8)))
    }

    func testTheQuestionGoesToRdapOrg() {
        XCTAssertEqual(RDAP.url(for: "acme.co.uk")?.absoluteString, "https://rdap.org/domain/acme.co.uk")
    }

    func testStages() {
        XCTAssertEqual(DomainStage.of(expiry: nil, now: start), .fine)
        XCTAssertEqual(DomainStage.of(expiry: start.addingTimeInterval(31 * day), now: start), .fine)
        XCTAssertEqual(DomainStage.of(expiry: start.addingTimeInterval(30 * day), now: start), .soon)
        XCTAssertEqual(DomainStage.of(expiry: start.addingTimeInterval(7 * day), now: start), .urgent)
        XCTAssertEqual(DomainStage.of(expiry: start.addingTimeInterval(-1), now: start), .expired)
    }

    func testEachThresholdIsSaidOnce() {
        let expiry = start.addingTimeInterval(40 * day)
        var state = SiteState()
        var said: [EventKind] = []
        // Asked every day for six weeks, like the real thing.
        for elapsed in 0..<45 {
            let folded = Detector.afterDomain(site: site, state: state, domain: "acme-rockets.com", expiry: expiry, now: start.addingTimeInterval(Double(elapsed) * day))
            state = folded.state
            said += folded.events.map(\.kind)
        }
        XCTAssertEqual(said, [.domainSoon, .domainUrgent, .domainExpired])
    }

    func testWordingAndLevels() {
        let soon = Detector.afterDomain(site: site, state: SiteState(), domain: "acme-rockets.com", expiry: start.addingTimeInterval(29.5 * day), now: start)
        XCTAssertEqual(soon.events.first?.message, "The domain acme-rockets.com expires in 29 days.")
        XCTAssertEqual(soon.events.first?.brief, "Domain expires in 29 days.")
        XCTAssertEqual(soon.events.first?.level, .warning)
        let urgent = Detector.afterDomain(site: site, state: soon.state, domain: "acme-rockets.com", expiry: start.addingTimeInterval(6.5 * day), now: start)
        XCTAssertEqual(urgent.events.first?.message, "The domain acme-rockets.com expires in 6 days.")
        XCTAssertEqual(urgent.events.first?.level, .critical)
        XCTAssertEqual(Health.of({ var s = urgent.state; s.lastPulse = start; return s }(), now: start).note, "Domain expires in 6 days")
        let gone = Detector.afterDomain(site: site, state: urgent.state, domain: "acme-rockets.com", expiry: start.addingTimeInterval(-day), now: start)
        XCTAssertEqual(gone.events.first?.message, "The domain acme-rockets.com has expired. Renew it before the address stops working.")
    }

    func testNoAnswerKeepsTheLastDateAndSaysNothingNew() {
        let first = Detector.afterDomain(site: site, state: SiteState(), domain: "acme-rockets.com", expiry: start.addingTimeInterval(20 * day), now: start)
        XCTAssertEqual(first.events.count, 1)
        let silent = Detector.afterDomain(site: site, state: first.state, domain: "acme-rockets.com", expiry: nil, now: start.addingTimeInterval(day))
        XCTAssertTrue(silent.events.isEmpty)
        XCTAssertEqual(silent.state.domainExpiry, first.state.domainExpiry)
        // Never any answer at all: nothing is known and nothing is said.
        let never = Detector.afterDomain(site: site, state: SiteState(), domain: "acme-rockets.com", expiry: nil, now: start)
        XCTAssertTrue(never.events.isEmpty)
        XCTAssertNil(never.state.domainExpiry)
        XCTAssertEqual(never.state.domainChecked, start)
    }

    func testARenewedDomainCanWarnAgainNextYear() {
        let warned = Detector.afterDomain(site: site, state: SiteState(), domain: "acme-rockets.com", expiry: start.addingTimeInterval(5 * day), now: start)
        let renewed = Detector.afterDomain(site: site, state: warned.state, domain: "acme-rockets.com", expiry: start.addingTimeInterval(370 * day), now: start.addingTimeInterval(day))
        XCTAssertTrue(renewed.events.isEmpty)
        XCTAssertEqual(renewed.state.domainStage, .fine)
        let again = Detector.afterDomain(site: site, state: renewed.state, domain: "acme-rockets.com", expiry: start.addingTimeInterval(370 * day), now: start.addingTimeInterval(345 * day))
        XCTAssertEqual(again.events.map(\.kind), [.domainSoon])
    }

    func testAskedOnceADay() {
        var state = SiteState()
        let settings = WatchSettings()
        XCTAssertFalse(Scheduler.domainDue(Entry(site: site, state: state), settings: settings, now: start), "not before the site has answered once")
        state.lastPulse = start
        XCTAssertTrue(Scheduler.domainDue(Entry(site: site, state: state), settings: settings, now: start))
        state.domainChecked = start
        XCTAssertFalse(Scheduler.domainDue(Entry(site: site, state: state), settings: settings, now: start.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(Scheduler.domainDue(Entry(site: site, state: state), settings: settings, now: start.addingTimeInterval(24 * 3600)))
        // Never for an address with no domain of its own, and never with the setting off.
        let local = Site(url: "http://localhost:3000/", host: "localhost", added: start)
        XCTAssertFalse(Scheduler.domainDue(Entry(site: local, state: state), settings: settings, now: start.addingTimeInterval(2 * day)))
        var off = settings
        off.domainExpiry = false
        XCTAssertFalse(Scheduler.domainDue(Entry(site: site, state: state), settings: off, now: start.addingTimeInterval(2 * day)))
    }
}

final class DomainWatcherTests: XCTestCase {
    private var directory: URL!
    private var pulser: StubPulser!
    private var domains: StubDomains!
    private var clock: TestClock!

    override func setUp() {
        directory = scratch()
        pulser = StubPulser()
        domains = StubDomains()
        clock = TestClock(start)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func watcher() -> Watcher {
        let clock = self.clock!
        return Watcher(store: Store(directory: directory), pulser: pulser, auditor: StubAuditor(), domains: domains, sideDoor: StubSideDoor(), clock: { clock.now })
    }

    func testTheRegistryIsAskedForTheRegistrableDomainOnceADay() async {
        let watcher = watcher()
        pulser.queue("shop.acme.co.uk", up)
        domains.queue(.expires(start.addingTimeInterval(20 * day)))
        guard case .added(let added) = await watcher.add("https://shop.acme.co.uk") else { return XCTFail("not added") }

        var due = await watcher.domainsDue()
        XCTAssertEqual(due, [added.id])
        let events = await watcher.checkDomain(added.id)
        XCTAssertEqual(domains.asked, ["acme.co.uk"])
        XCTAssertEqual(events.map(\.message), ["The domain acme.co.uk expires in 20 days."])
        due = await watcher.domainsDue()
        XCTAssertEqual(due, [])

        clock.advance(day)
        due = await watcher.domainsDue()
        XCTAssertEqual(due, [added.id])
        let again = await watcher.checkDomain(added.id)
        XCTAssertTrue(again.isEmpty, "said once")
        let log = await watcher.events
        XCTAssertEqual(log.filter { $0.kind == .domainSoon }.count, 1)
    }

    func testNoAnswerIsSkippedQuietlyAndAnUnreachableRegistryIsAskedAgainSooner() async {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", up)
        domains.queue(.unknown, .unreachable, .unknown)
        guard case .added(let added) = await watcher.add("acme-rockets.com") else { return XCTFail("not added") }

        var events = await watcher.checkDomain(added.id)
        XCTAssertTrue(events.isEmpty)
        var due = await watcher.domainsDue()
        XCTAssertEqual(due, [], "the registry had nothing to say, so not again today")

        clock.advance(day)
        events = await watcher.checkDomain(added.id)
        XCTAssertTrue(events.isEmpty)
        clock.advance(1800)
        due = await watcher.domainsDue()
        XCTAssertEqual(due, [], "never arrived: not straight away")
        clock.advance(1800)
        due = await watcher.domainsDue()
        XCTAssertEqual(due, [added.id], "but in an hour, not tomorrow")
    }

    func testSwitchedOffNothingIsAsked() async {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", up)
        guard case .added(let added) = await watcher.add("acme-rockets.com") else { return XCTFail("not added") }
        var settings = await watcher.settings
        settings.domainExpiry = false
        await watcher.set(settings)
        let due = await watcher.domainsDue()
        XCTAssertEqual(due, [])
        let events = await watcher.checkDomain(added.id)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(domains.asked, [])
    }
}

// MARK: Must contain

final class PhraseTests: XCTestCase {
    func testFinding() {
        XCTAssertTrue(Phrase.found("Add to cart", in: "<button>Add to cart</button>"))
        XCTAssertTrue(Phrase.found("add to CART", in: "<button>Add to cart</button>"), "case does not matter")
        XCTAssertTrue(Phrase.found("Add to cart", in: "<button>Add\n      to   cart</button>"), "nor spacing")
        XCTAssertTrue(Phrase.found("Add to cart", in: "<b>Add</b>&nbsp;to cart"), "nor tags and entities inside it")
        XCTAssertTrue(Phrase.found("Add to cart", in: "<span>Add</span><span>to cart</span>"))
        XCTAssertTrue(Phrase.found("Tom & Jerry's", in: "<h1>Tom &amp; Jerry&#39;s</h1>"))
        XCTAssertFalse(Phrase.found("Add to cart", in: "<h1>502 Bad Gateway</h1>"))
        XCTAssertFalse(Phrase.found("Add to cart", in: ""))
    }

    func testCleaning() {
        XCTAssertNil(Phrase.cleaned(nil))
        XCTAssertNil(Phrase.cleaned("   \n"))
        XCTAssertEqual(Phrase.cleaned("  Add   to\tcart "), "Add to cart")
        XCTAssertEqual(Phrase.cleaned(String(repeating: "a", count: 200))?.count, Phrase.longest)
    }

    func testOneMissIsNotMissing() {
        let folded = fold([page("<h1>Oops</h1>")], on: shop)
        XCTAssertTrue(folded.events.isEmpty)
        XCTAssertEqual(folded.state.phraseMisses, 1)
        XCTAssertNil(folded.state.missingPhrase)
        // And it is looked at again in half a minute, like a failed pulse.
        XCTAssertTrue(Scheduler.pulseDue(folded.state, settings: WatchSettings(), now: start.addingTimeInterval(30)))
        XCTAssertFalse(Scheduler.pulseDue(fold([page("Add to cart")], on: shop).state, settings: WatchSettings(), now: start.addingTimeInterval(30)))
    }

    func testAnOddAnswerIsForgotten() {
        let folded = fold([page("Add to cart"), page("Oops"), page("Add to cart"), page("Oops")], on: shop)
        XCTAssertTrue(folded.events.isEmpty)
    }

    func testTwoMissesInARowAreReportedOnceAndTheReturnIsReported() {
        let gone = fold([page("Add to cart"), page("Oops"), page("Oops"), page("Oops"), page("Oops")], on: shop)
        XCTAssertEqual(gone.events.map(\.kind), [.phraseMissing])
        XCTAssertEqual(gone.events.first?.message, "lumen-bikes.com is up but missing “Add to cart”.")
        XCTAssertEqual(gone.events.first?.brief, "Up but missing “Add to cart”.")
        XCTAssertEqual(gone.events.first?.level, .critical)
        XCTAssertEqual(gone.state.missingPhrase, "Add to cart")
        XCTAssertFalse(gone.state.isDown, "the site is up; that is the point")

        var health = gone.state
        health.lastPulse = start
        XCTAssertEqual(Health.of(health, now: start), Health(condition: .critical, note: "Up but missing “Add to cart”"))

        let back = Detector.afterPulse(site: shop, state: gone.state, result: page("<a>Add to cart</a>"), history: [], now: start.addingTimeInterval(3000))
        XCTAssertEqual(back.events.map(\.message), ["lumen-bikes.com shows “Add to cart” again."])
        XCTAssertEqual(back.events.first?.level, .good)
        XCTAssertNil(back.state.missingPhrase)
        let after = Detector.afterPulse(site: shop, state: back.state, result: page("Add to cart"), history: [], now: start.addingTimeInterval(3300))
        XCTAssertTrue(after.events.isEmpty, "said once")
    }

    func testAPulseThatDidNotReadThePageJudgesNothing() {
        let folded = fold([up, up, up], on: shop)
        XCTAssertTrue(folded.events.isEmpty)
        XCTAssertNil(folded.state.phraseMisses)
    }

    func testASiteWithNoPhraseIsNeverJudged() {
        XCTAssertTrue(fold([page("Oops"), page("Oops"), page("Oops")], on: site).events.isEmpty)
    }

    func testAFailedPulseIsDownNotMissing() {
        let folded = fold([page("Add to cart"), refused, refused], on: shop)
        XCTAssertEqual(folded.events.map(\.kind), [.down])
    }
}

final class PhraseWatcherTests: XCTestCase {
    private var directory: URL!
    private var pulser: StubPulser!
    private var clock: TestClock!

    override func setUp() {
        directory = scratch()
        pulser = StubPulser()
        clock = TestClock(start)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func watcher() -> Watcher {
        let clock = self.clock!
        return Watcher(store: Store(directory: directory), pulser: pulser, auditor: StubAuditor(), domains: StubDomains(), sideDoor: StubSideDoor(), clock: { clock.now })
    }

    func testThePageIsReadOnlyForASiteWithAPhraseAndTheErrorPageIsCaught() async {
        var watcher = watcher()
        let error = PulseResult(status: 200, milliseconds: 180, body: "<title>Something went wrong</title><h1>Error</h1>", finalURL: "https://lumen-bikes.com/")
        pulser.queue("lumen-bikes.com", up, page("<button>Add to cart</button>"), error, error, page("<button>Add to cart</button>"))
        guard case .added(let added) = await watcher.add("lumen-bikes.com") else { return XCTFail("not added") }
        XCTAssertEqual(pulser.read, [], "no phrase, so only the answer is wanted")

        await watcher.setPhrase(added.id, "  Add to cart ")
        watcher = self.watcher()                      // the phrase is kept across a restart
        let kept = await watcher.entries.first?.site.mustContain
        XCTAssertEqual(kept, "Add to cart")

        clock.advance(300)
        var outcome = await watcher.pulseDue()
        XCTAssertEqual(pulser.read, ["lumen-bikes.com"])
        XCTAssertTrue(outcome.events.isEmpty)

        clock.advance(300)
        outcome = await watcher.pulseDue()
        XCTAssertTrue(outcome.events.isEmpty, "one miss")
        clock.advance(30)
        outcome = await watcher.pulseDue()
        XCTAssertEqual(outcome.events.map(\.full), ["lumen-bikes.com is up but missing “Add to cart”. The page's title is now “Something went wrong”."])

        clock.advance(300)
        outcome = await watcher.pulseDue()
        XCTAssertEqual(outcome.events.map(\.kind), [.phraseBack])
    }

    func testChangingOrClearingThePhraseStartsAfresh() async {
        let watcher = watcher()
        pulser.queue("lumen-bikes.com", up, page("Oops"), page("Oops"))
        guard case .added(let added) = await watcher.add("lumen-bikes.com") else { return XCTFail("not added") }
        await watcher.setPhrase(added.id, "Add to cart")
        clock.advance(300)
        _ = await watcher.pulseDue()
        clock.advance(30)
        let outcome = await watcher.pulseDue()
        XCTAssertEqual(outcome.events.map(\.kind), [.phraseMissing])

        await watcher.setPhrase(added.id, "")
        let entry = await watcher.entries.first
        XCTAssertNil(entry?.site.mustContain)
        XCTAssertNil(entry?.state.missingPhrase)
        XCTAssertNil(entry?.state.phraseMisses)
    }
}

// MARK: Webhook

final class WebhookTests: XCTestCase {
    private let slack = "https://hooks.slack.com/services/T000/B000/XXXX"
    private let discord = "https://discord.com/api/webhooks/123/abc"
    private let other = "https://example.com/hooks/launchwatch"

    private func event(_ message: String = "acme-rockets.com is down: it answered with error 502.", cause: String? = nil) -> SiteEvent {
        SiteEvent(site: site, kind: .down, level: .critical, message: message, brief: "Down.", date: at(2027, 1, 20, 13), cause: cause)
    }

    private func body(_ request: URLRequest?) -> [String: Any] {
        guard let data = request?.httpBody, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    func testNoAddressNoRequest() {
        let message = Webhook.Message(event())
        XCTAssertNil(Webhook.request(to: nil, message))
        XCTAssertNil(Webhook.request(to: "", message))
        XCTAssertNil(Webhook.request(to: "   ", message))
        XCTAssertNil(Webhook.request(to: "not an address", message))
        XCTAssertNil(Webhook.request(to: "hooks.slack.com/services/T000", message), "no scheme, no request")
        XCTAssertNil(Webhook.request(to: "ftp://example.com/hook", message))
        XCTAssertNil(Webhook.request(to: "file:///tmp/hook", message))
        XCTAssertNil(WatchSettings().webhook, "and there is no address until someone enters one")
    }

    func testTheShapeFollowsTheHost() {
        XCTAssertEqual(Webhook.flavor(of: URL(string: slack)!), .slack)
        XCTAssertEqual(Webhook.flavor(of: URL(string: discord)!), .discord)
        XCTAssertEqual(Webhook.flavor(of: URL(string: "https://discordapp.com/api/webhooks/1/a")!), .discord)
        XCTAssertEqual(Webhook.flavor(of: URL(string: "https://discord.com/invite/abc")!), .plain, "only a webhook address is a webhook")
        XCTAssertEqual(Webhook.flavor(of: URL(string: other)!), .plain)
        XCTAssertEqual(Webhook.flavor(of: URL(string: "https://hooks.slack.com.evil.example/x")!), .plain)
    }

    func testSlackGetsText() {
        let request = Webhook.request(to: " \(slack)\n", Webhook.Message(event()))
        XCTAssertEqual(request?.url?.absoluteString, slack)
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(body(request) as? [String: String], ["text": "acme-rockets.com is down: it answered with error 502."])
    }

    func testSlackMarkupIsEscaped() {
        let request = Webhook.request(to: slack, Webhook.Message(event("The home page title of acme-rockets.com changed to “<!channel> Sale & more”.")))
        XCTAssertEqual(body(request)["text"] as? String, "The home page title of acme-rockets.com changed to “&lt;!channel&gt; Sale &amp; more”.")
    }

    func testDiscordGetsContentAndRingsNobody() {
        let long = String(repeating: "x", count: 3000)
        let sent = body(Webhook.request(to: discord, Webhook.Message(event("@everyone \(long)"))))
        XCTAssertEqual((sent["content"] as? String)?.count, 2000)
        XCTAssertEqual((sent["allowed_mentions"] as? [String: [String]])?["parse"], [])
        XCTAssertNil(sent["text"])
    }

    func testAnyoneElseGetsPlainJSON() {
        let sent = body(Webhook.request(to: other, Webhook.Message(event(cause: "Error 502 usually means the host cannot reach the app behind it."))))
        XCTAssertEqual(sent["text"] as? String, "acme-rockets.com is down: it answered with error 502. Error 502 usually means the host cannot reach the app behind it.")
        XCTAssertEqual(sent["cause"] as? String, "Error 502 usually means the host cannot reach the app behind it.")
        XCTAssertEqual(sent["site"] as? String, "acme-rockets.com")
        XCTAssertEqual(sent["kind"] as? String, "down")
        XCTAssertEqual(sent["level"] as? String, "critical")
        XCTAssertEqual(sent["date"] as? String, "2027-01-20T13:00:00Z")
        XCTAssertEqual(sent["source"] as? String, "Launchwatch")
    }

    func testTheCauseTravelsInTheTextEverywhere() {
        let message = Webhook.Message(event(cause: "The certificate ran out on 12 Jan 2027."))
        XCTAssertEqual(body(Webhook.request(to: slack, message))["text"] as? String, "acme-rockets.com is down: it answered with error 502. The certificate ran out on 12 Jan 2027.")
        XCTAssertEqual(body(Webhook.request(to: discord, message))["content"] as? String, "acme-rockets.com is down: it answered with error 502. The certificate ran out on 12 Jan 2027.")
    }

    func testTheSummaryAndTheTest() {
        let summary = WeekSummary(date: at(2027, 1, 18, 9), sites: 6, uptime: 1)
        XCTAssertEqual(body(Webhook.request(to: slack, Webhook.Message(summary)))["text"] as? String, "Last week: all 6 sites stayed up.")
        let test = body(Webhook.request(to: other, .test(now: at(2027, 1, 20))))
        XCTAssertEqual(test["kind"] as? String, "test")
        XCTAssertNil(test["site"])
    }

    func testFailuresInWords() {
        XCTAssertNil(Webhook.problem(status: 200))
        XCTAssertNil(Webhook.problem(status: 204), "Discord answers 204")
        XCTAssertEqual(Webhook.problem(status: 404), "The webhook no longer exists (error 404).")
        XCTAssertEqual(Webhook.problem(status: 500), "The webhook answered with error 500.")
        XCTAssertNotNil(Webhook.problem(status: 403))
        XCTAssertNotNil(Webhook.problem(status: 429))
    }

    func testTheAddressIsKeptWithTheSettings() throws {
        var settings = WatchSettings()
        settings.webhook = slack
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(WatchSettings.self, from: data).webhook, slack)
    }
}

// MARK: Response chart

final class ChartTests: XCTestCase {
    func testBuiltFromTheStoredDayInQuarterHours() {
        let now = start.addingTimeInterval(day)
        var checks: [Sample] = []
        for index in 0..<288 { checks.append(Sample(date: start.addingTimeInterval(Double(index) * 300 + 10), status: 200, milliseconds: index == 100 ? 900 : 200)) }
        checks.append(Sample(date: start.addingTimeInterval(-3600), status: 200, milliseconds: 5000))      // older than a day: not drawn
        let chart = Stats.chart(checks, now: now)
        XCTAssertEqual(chart.buckets.count, 96)
        XCTAssertEqual(chart.median, 200)
        XCTAssertEqual(chart.fastest, 200)
        XCTAssertEqual(chart.slowest, 433, "the spike, averaged with its two neighbours in the quarter hour")
        XCTAssertTrue(chart.hasReadings)
        XCTAssertEqual(chart.spoken, "Response over the last 24 hours: usually 200 ms, slowest 433 ms.")
    }

    func testTheUsualTimeSitsHalfWayUpUnlessSomethingSpikes() {
        let calm = ResponseChart(buckets: [.up(200), .up(210)], median: 200, slowest: 210, fastest: 200)
        XCTAssertEqual(calm.top, 400)
        XCTAssertEqual(calm.height(of: 200), 0.5)
        let spiky = ResponseChart(buckets: [.up(200), .up(1000)], median: 200, slowest: 1000, fastest: 200)
        XCTAssertEqual(spiky.top, 1000)
        XCTAssertEqual(spiky.height(of: 200), 0.2)
        XCTAssertEqual(spiky.height(of: 5000), 1, "never off the top")
        XCTAssertEqual(spiky.height(of: 0), 0)
    }

    func testOutagesGapsAndNothingAtAll() {
        let now = start.addingTimeInterval(day)
        let checks = [Sample(date: start.addingTimeInterval(100), status: 200, milliseconds: 300), Sample(date: now.addingTimeInterval(-100), status: 0, milliseconds: 0)]
        let chart = Stats.chart(checks, now: now)
        XCTAssertEqual(chart.buckets.first, .up(300))
        XCTAssertEqual(chart.buckets.last, .down)
        XCTAssertEqual(chart.buckets[40], .empty)
        XCTAssertEqual(chart.spoken, "Response over the last 24 hours: usually 300 ms, slowest 300 ms. Some checks failed.")

        let none = Stats.chart([], now: now)
        XCTAssertFalse(none.hasReadings)
        XCTAssertNil(none.median)
        XCTAssertEqual(none.height(of: 100), 1, "nothing to scale against, and still never off the top")
        XCTAssertEqual(none.spoken, "No response times in the last 24 hours.")
        XCTAssertFalse(ResponseChart.empty.hasReadings)
    }

    func testTheRowCarriesItsChart() {
        var state = SiteState()
        state.lastPulse = start
        let checks = [Sample(date: start.addingTimeInterval(-600), status: 200, milliseconds: 240)]
        XCTAssertEqual(SiteSummary.make(Entry(site: site, state: state), samples: checks, events: [], now: start).chart.median, 240)
    }
}

// MARK: Old files

final class OldDataTests: XCTestCase {
    /// The keys 0.2.0 wrote, with invented values: no pause, no phrase, no domain, no webhook, no cause, no phases.
    private let library = """
    {"entries":[{"site":{"added":1800000000,"host":"acme-rockets.com","id":"0B1E5C6E-4C0B-4B4E-9C39-6D3B6B0A2F11","url":"https://acme-rockets.com/"},\
    "state":{"audited":1800003000,"blockers":2,"certificateExpiry":1805000000,"certificateStage":0,"failures":0,"homeNoindex":false,"isDown":false,\
    "lastAuditAttempt":1800003000,"lastMilliseconds":240,"lastPulse":1800003600,"pagesChecked":25,"robotsBlocked":false,"score":77,"slow":false,"slowStreak":0}}],\
    "events":[{"brief":"Down: the server refused the connection.","date":1800001000,"host":"acme-rockets.com","id":"5D2C1B9A-7A53-4C06-9B5B-0C2E6C8F3A10",\
    "kind":"down","level":0,"message":"acme-rockets.com is down: the server refused the connection.","site":"0B1E5C6E-4C0B-4B4E-9C39-6D3B6B0A2F11"}],\
    "settings":{"auditHours":6,"notifications":true,"pulseMinutes":5,"weeklySummary":true},"weekHandled":1799900000}
    """
    private let samples = #"[{"m":240,"s":200,"t":1800003300},{"m":0,"s":0,"t":1800003600}]"#

    func testEverythingWrittenByTheLastVersionStillLoads() async throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("samples"), withIntermediateDirectories: true)
        try Data(library.utf8).write(to: directory.appendingPathComponent("library.json"))
        try Data(samples.utf8).write(to: directory.appendingPathComponent("samples/0B1E5C6E-4C0B-4B4E-9C39-6D3B6B0A2F11.json"))

        let store = Store(directory: directory)
        let loaded = store.loadLibrary()
        XCTAssertEqual(loaded.entries.count, 1)
        let entry = try XCTUnwrap(loaded.entries.first)
        XCTAssertEqual(entry.site.host, "acme-rockets.com")
        XCTAssertNil(entry.site.mustContain)
        XCTAssertEqual(entry.state.score, 77)
        XCTAssertNil(entry.state.pause)
        XCTAssertNil(entry.state.pauses)
        XCTAssertNil(entry.state.missingPhrase)
        XCTAssertNil(entry.state.domainExpiry)
        XCTAssertNil(entry.state.domainStage)
        XCTAssertEqual(loaded.events.count, 1)
        XCTAssertNil(loaded.events.first?.cause)
        XCTAssertEqual(loaded.events.first?.full, "acme-rockets.com is down: the server refused the connection.")
        XCTAssertNil(loaded.settings.webhook)
        XCTAssertTrue(loaded.settings.domainExpiry, "on unless it was turned off")
        XCTAssertEqual(store.samples(for: entry.site.id).count, 2)
        XCTAssertNil(store.samples(for: entry.site.id).first?.phases)

        // And the new version carries on from it: the site is watched, not paused, and its issues wait for the next audit.
        let moment = Date(timeIntervalSince1970: 1_800_004_000)
        let watcher = Watcher(store: store, pulser: StubPulser(), auditor: StubAuditor(), domains: StubDomains(), sideDoor: StubSideDoor(), clock: { moment })
        let summary = await watcher.summaries().first
        XCTAssertEqual(summary?.health.condition, .fine)
        XCTAssertEqual(summary?.chart.median, 240)
        let due = await watcher.domainsDue()
        XCTAssertEqual(due, [entry.site.id])
        let issues = await watcher.issues(for: entry.site.id)
        XCTAssertNil(issues, "no report kept yet: the view says details appear after the next check")
    }

    func testTheNewFieldsRoundTrip() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = SiteState()
        state.pause = Pause(since: start, until: nil)
        state.pauses = [Pause(since: start.addingTimeInterval(-7200), until: start.addingTimeInterval(-3600))]
        state.phraseMisses = 2
        state.missingPhrase = "Add to cart"
        state.domainChecked = start
        state.domainExpiry = start.addingTimeInterval(20 * day)
        state.domainStage = .soon
        var library = Library()
        library.entries = [Entry(site: shop, state: state)]
        library.events = [SiteEvent(site: shop, kind: .slow, level: .warning, message: "Slow.", brief: "Slow.", date: start, cause: "Waiting for the server took 1.6 s, usually 180 ms.")]
        library.settings.webhook = "https://example.com/hook"
        library.settings.domainExpiry = false
        let store = Store(directory: directory)
        store.save(library)
        XCTAssertEqual(store.loadLibrary(), library)

        let kept = [Sample(date: start, status: 200, milliseconds: 300, phases: PhaseTimings(lookup: 10, connect: 20, secure: 40, wait: 230))]
        store.save(kept, for: shop.id)
        XCTAssertEqual(store.samples(for: shop.id), kept)
    }
}
