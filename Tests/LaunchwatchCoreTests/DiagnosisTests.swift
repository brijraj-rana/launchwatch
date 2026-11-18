import LaunchcheckCore
import XCTest
@testable import LaunchwatchCore

// The likely cause of an event, and the issue list. Every sample here is invented: headers and pages written
// to carry the marks the classifier looks for, not copied from a live error page.

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let site = Site(url: "https://acme-rockets.com/", host: "acme-rockets.com", added: start)
private let day: TimeInterval = 86_400

private func evidence(failure: PulseFailure? = nil, status: Int = 0, headers: [String: String] = [:], sample: String = "", finalURL: String? = nil,
                      domainExpiry: Date? = nil, sideDoor: SideDoor = .notAsked) -> DownEvidence {
    DownEvidence(host: "acme-rockets.com", failure: failure, status: status, headers: headers, sample: sample, finalURL: finalURL,
                 domainExpiry: domainExpiry, sideDoor: sideDoor, now: start)
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("launchwatch-tests-\(UUID().uuidString)", isDirectory: true)
}

// MARK: Down

final class DownCauseTests: XCTestCase {
    func testTheNameDoesNotResolve() {
        let cause = Diagnosis.down(evidence(failure: .nameNotFound))
        XCTAssertEqual(cause?.kind, .nameNotFound)
        XCTAssertEqual(cause?.sentence, "The name does not resolve, so the trouble is with DNS or the domain and not with the server.")
        // The registry's date is known and still ahead: the registration is not the reason.
        XCTAssertEqual(Diagnosis.down(evidence(failure: .nameNotFound, domainExpiry: start.addingTimeInterval(90 * day)))?.kind, .nameNotFound)
    }

    func testTheNameDoesNotResolveBecauseTheDomainLapsed() {
        let lapsed = Date(timeIntervalSince1970: 1_799_539_200)      // 10 Jan 2027
        let cause = Diagnosis.down(evidence(failure: .nameNotFound, domainExpiry: lapsed))
        XCTAssertEqual(cause?.kind, .domainLapsed)
        XCTAssertEqual(cause?.sentence, "The domain registration ran out on 10 Jan 2027, which is likely why the name no longer resolves.")
    }

    func testCertificates() {
        let then = Date(timeIntervalSince1970: 1_799_539_200)
        XCTAssertEqual(Diagnosis.down(evidence(failure: .certificate(.expired(then)))), Cause(.certificateExpired, "The certificate ran out on 10 Jan 2027."))
        XCTAssertEqual(Diagnosis.down(evidence(failure: .certificate(.expired(nil))))?.sentence, "The certificate has run out.")
        XCTAssertEqual(Diagnosis.down(evidence(failure: .certificate(.notYetValid(then)))), Cause(.certificateNotYetValid, "The certificate is not valid until 10 Jan 2027."))
        XCTAssertEqual(Diagnosis.down(evidence(failure: .certificate(.notYetValid(nil))))?.sentence, "The certificate is not valid yet.")
        XCTAssertEqual(Diagnosis.down(evidence(failure: .certificate(.wrongHost))), Cause(.certificateWrongHost, "The certificate is for a different name, not acme-rockets.com."))
        XCTAssertEqual(Diagnosis.down(evidence(failure: .certificate(.untrusted)))?.kind, .certificateUntrusted)
        // The certificate was refused and nothing more could be told: say nothing rather than guess.
        XCTAssertNil(Diagnosis.down(evidence(failure: .certificate(nil))))
    }

    func testRefusedTimedOutAndDropped() {
        XCTAssertEqual(Diagnosis.down(evidence(failure: .refused))?.kind, .refused)
        XCTAssertTrue(Diagnosis.down(evidence(failure: .refused))?.sentence.contains("likely stopped") ?? false)
        XCTAssertEqual(Diagnosis.down(evidence(failure: .timedOut))?.kind, .timedOut)
        XCTAssertTrue(Diagnosis.down(evidence(failure: .timedOut))?.sentence.contains("likely overloaded") ?? false)
        XCTAssertEqual(Diagnosis.down(evidence(failure: .dropped))?.kind, .dropped)
    }

    func testErrorStatuses() {
        func says(_ status: Int) -> String? { Diagnosis.down(evidence(status: status))?.sentence }
        XCTAssertEqual(says(500), "Error 500 usually means the site's own code failed.")
        XCTAssertEqual(says(502), "Error 502 usually means the host cannot reach the app behind it.")
        XCTAssertEqual(says(504), "Error 504 usually means the host cannot reach the app behind it.")
        XCTAssertEqual(says(503), "Error 503 usually means the server is overloaded or in maintenance.")
        XCTAssertEqual(says(403), "Error 403 usually means the server is blocking visitors.")
        XCTAssertEqual(says(404), "Error 404 usually means the home page is gone.")
        XCTAssertEqual(says(401), "Error 401 usually means the site now asks for a password.")
        XCTAssertEqual(says(429), "Error 429 usually means the server is turning away requests that come too often.")
        XCTAssertEqual(Diagnosis.down(evidence(status: 500))?.kind, .status)
        // A code with no usual meaning: nothing extra.
        XCTAssertNil(says(418))
        XCTAssertNil(says(599))
    }

    func testCloudflareCannotReachTheOrigin() {
        let headers = ["cf-ray": "8e1a2b3c4d5e6f70-LHR", "server": "cloudflare"]
        let cause = Diagnosis.down(evidence(status: 522, headers: headers, sample: "<title>acme-rockets.com | 522: Connection timed out</title>"))
        XCTAssertEqual(cause?.kind, .cloudflareOrigin)
        XCTAssertEqual(cause?.sentence, "Cloudflare is up but the server behind it did not answer in time (error 522), so the trouble is at the host and not at Cloudflare.")
        for status in [520, 521, 523, 524, 525, 526, 530] {
            XCTAssertEqual(Diagnosis.down(evidence(status: status, headers: headers))?.kind, .cloudflareOrigin, "\(status)")
        }
        // Without Cloudflare's marks a 522 is just an odd number.
        XCTAssertNil(Diagnosis.down(evidence(status: 522)))
    }

    func testCloudflareItself() {
        let headers = ["cf-ray": "8e1a2b3c4d5e6f70-LHR", "server": "cloudflare"]
        let own = Diagnosis.down(evidence(status: 500, headers: headers, sample: "<div id=\"cf-wrapper\"><div id=\"cf-error-details\">Internal server error</div></div>"))
        XCTAssertEqual(own, Cause(.cloudflareItself, "Likely Cloudflare itself: the error page is Cloudflare's own, not the site's."))
        // The site's own error, passed through Cloudflare untouched: Cloudflare is not blamed.
        let passed = Diagnosis.down(evidence(status: 500, headers: headers, sample: "<h1>Application error</h1>"))
        XCTAssertEqual(passed?.kind, .status)
    }

    func testVercel() {
        let named = Diagnosis.down(evidence(status: 404, headers: ["x-vercel-error": "DEPLOYMENT_NOT_FOUND", "x-vercel-id": "lhr1::abcde-1700000000000-0123456789ab", "server": "Vercel"]))
        XCTAssertEqual(named, Cause(.platform, "Vercel says DEPLOYMENT_NOT_FOUND: the deployment is gone or the domain no longer points at one."))
        let failed = Diagnosis.down(evidence(status: 500, headers: ["x-vercel-error": "FUNCTION_INVOCATION_FAILED"]))
        XCTAssertEqual(failed?.sentence, "Vercel says FUNCTION_INVOCATION_FAILED: the site's own code failed.")
        // No error name, or one that is not known: named as the likely host, with what the code usually means.
        let likely = Diagnosis.down(evidence(status: 502, headers: ["x-vercel-id": "lhr1::abcde-1700000000000-0123456789ab"]))
        XCTAssertEqual(likely, Cause(.platform, "Likely the host: 502 from Vercel, which usually means the host cannot reach the app behind it."))
        XCTAssertEqual(Diagnosis.down(evidence(status: 500, headers: ["x-vercel-error": "SOMETHING_NEW", "server": "Vercel"]))?.sentence,
                       "Likely the host: 500 from Vercel, which usually means the site's own code failed.")
    }

    func testNetlifyWebflowAndGitHubPages() {
        XCTAssertEqual(Diagnosis.platform(headers: ["x-nf-request-id": "01HXYZ", "server": "Netlify"], sample: ""), .netlify)
        XCTAssertEqual(Diagnosis.platform(headers: ["server": "Netlify"], sample: ""), .netlify)
        XCTAssertEqual(Diagnosis.platform(headers: ["x-github-request-id": "AB12:34CD:5678"], sample: ""), .githubPages)
        XCTAssertEqual(Diagnosis.platform(headers: ["server": "GitHub.com"], sample: ""), .githubPages)
        XCTAssertEqual(Diagnosis.platform(headers: ["x-wf-region": "us-east-1"], sample: ""), .webflow)
        XCTAssertEqual(Diagnosis.platform(headers: ["server": "cloudflare", "cf-ray": "1"], sample: "<html data-wf-site=\"64f0\">"), .webflow, "Webflow behind Cloudflare is Webflow")
        XCTAssertEqual(Diagnosis.platform(headers: ["cf-ray": "1"], sample: ""), .cloudflare)
        XCTAssertNil(Diagnosis.platform(headers: ["server": "nginx"], sample: "<h1>Not Found</h1>"))

        XCTAssertEqual(Diagnosis.down(evidence(status: 404, headers: ["x-nf-request-id": "01HXYZ"]))?.sentence,
                       "Netlify has no site for this address: the project was removed, unpublished or the domain was disconnected.")
        XCTAssertEqual(Diagnosis.down(evidence(status: 404, headers: ["server": "GitHub.com"]))?.sentence,
                       "GitHub Pages has no site for this address: the project was removed, unpublished or the domain was disconnected.")
        XCTAssertEqual(Diagnosis.down(evidence(status: 503, headers: ["x-wf-region": "us-east-1"]))?.sentence,
                       "Likely the host: 503 from Webflow, which usually means the server is overloaded or in maintenance.")
        XCTAssertEqual(Diagnosis.down(evidence(status: 418, headers: ["server": "Netlify"]))?.sentence, "Likely the host: 418 from Netlify.")
    }

    func testRedirects() {
        let loop = Diagnosis.down(evidence(failure: .redirectLoop, finalURL: "https://acme-rockets.com/login"))
        XCTAssertEqual(loop, Cause(.redirectLoop, "The loop was last seen at https://acme-rockets.com/login."))
        XCTAssertEqual(Diagnosis.down(evidence(failure: .redirectLoop))?.kind, .redirectLoop)

        let elsewhere = Diagnosis.down(evidence(status: 404, finalURL: "https://parked.example.net/lander"))
        XCTAssertEqual(elsewhere, Cause(.redirectElsewhere, "It now redirects to parked.example.net, which answers with error 404."))
        // www and the bare name are the same site.
        XCTAssertEqual(Diagnosis.down(evidence(status: 404, finalURL: "https://www.acme-rockets.com/"))?.kind, .status)
    }

    func testOnlyTheHomePageFails() {
        let up = Diagnosis.down(evidence(status: 500, sideDoor: .answered("/robots.txt")))
        XCTAssertEqual(up, Cause(.homePageOnly, "The server is up, the home page is failing: robots.txt still answers."))
        XCTAssertEqual(Diagnosis.down(evidence(status: 418, sideDoor: .answered("/favicon.ico")))?.sentence,
                       "The server is up, the home page is failing: favicon.ico still answers.")
        XCTAssertEqual(Diagnosis.down(evidence(failure: .timedOut, sideDoor: .answered("/robots.txt")))?.kind, .homePageOnly)
        // Nothing else answered either: back to what the code means.
        XCTAssertEqual(Diagnosis.down(evidence(status: 500, sideDoor: .silent))?.kind, .status)
        XCTAssertEqual(Diagnosis.down(evidence(failure: .timedOut, sideDoor: .silent))?.kind, .timedOut)
    }

    func testTheOrderStopsAtTheFirstExplanation() {
        // A platform's own explanation outranks the side door, which is then never asked.
        let cloudflare = evidence(status: 521, headers: ["cf-ray": "1"], sideDoor: .answered("/robots.txt"))
        XCTAssertEqual(Diagnosis.down(cloudflare)?.kind, .cloudflareOrigin)
        // A failure to connect outranks anything a status could say.
        XCTAssertEqual(Diagnosis.down(evidence(failure: .nameNotFound, status: 502, headers: ["cf-ray": "1"]))?.kind, .nameNotFound)
    }

    func testWhenTheSideDoorIsWorthAsking() {
        XCTAssertTrue(Diagnosis.wantsSideDoor(evidence(status: 500)))
        XCTAssertTrue(Diagnosis.wantsSideDoor(evidence(status: 404)))
        XCTAssertTrue(Diagnosis.wantsSideDoor(evidence(failure: .timedOut)))
        XCTAssertTrue(Diagnosis.wantsSideDoor(evidence(status: 500, headers: ["cf-ray": "1"], sample: "<h1>Application error</h1>")), "the site's own error behind Cloudflare")
        XCTAssertFalse(Diagnosis.wantsSideDoor(evidence(failure: .nameNotFound)))
        XCTAssertFalse(Diagnosis.wantsSideDoor(evidence(failure: .refused)))
        XCTAssertFalse(Diagnosis.wantsSideDoor(evidence(failure: .certificate(.wrongHost))))
        XCTAssertFalse(Diagnosis.wantsSideDoor(evidence(status: 522, headers: ["cf-ray": "1"])))
        XCTAssertFalse(Diagnosis.wantsSideDoor(evidence(status: 502, headers: ["x-vercel-id": "1"])))
        XCTAssertFalse(Diagnosis.wantsSideDoor(evidence(status: 200)), "never for a site that is fine")
    }

    func testNothingToGoOnSaysNothing() {
        XCTAssertNil(Diagnosis.down(evidence(failure: .other)))
        XCTAssertNil(Diagnosis.down(evidence()))
        XCTAssertNil(Diagnosis.down(evidence(status: 200)))
    }

    func testEveryCauseIsOneSentenceInThisAppsVoice() {
        let all: [DownEvidence] = [
            evidence(failure: .nameNotFound), evidence(failure: .nameNotFound, domainExpiry: start.addingTimeInterval(-day)),
            evidence(failure: .certificate(.expired(start))), evidence(failure: .certificate(.notYetValid(start))), evidence(failure: .certificate(.wrongHost)),
            evidence(failure: .certificate(.untrusted)), evidence(failure: .refused), evidence(failure: .timedOut), evidence(failure: .dropped),
            evidence(failure: .redirectLoop), evidence(failure: .redirectLoop, finalURL: "https://acme-rockets.com/a"),
            evidence(status: 500), evidence(status: 502), evidence(status: 503), evidence(status: 403), evidence(status: 404),
            evidence(status: 521, headers: ["cf-ray": "1"]), evidence(status: 500, headers: ["cf-ray": "1"], sample: "cf-error-details"),
            evidence(status: 500, headers: ["x-vercel-error": "FUNCTION_INVOCATION_FAILED"]), evidence(status: 502, headers: ["server": "Netlify"]),
            evidence(status: 404, headers: ["server": "GitHub.com"]), evidence(status: 404, finalURL: "https://elsewhere.example/"),
            evidence(status: 500, sideDoor: .answered("/robots.txt")), evidence(failure: .timedOut, sideDoor: .answered("/favicon.ico")),
        ]
        for one in all {
            guard let sentence = Diagnosis.down(one)?.sentence else { return XCTFail("no cause for \(one)") }
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
            XCTAssertFalse(sentence.contains("\u{2014}") || sentence.contains("\u{2013}") || sentence.contains("!"), sentence)
            XCTAssertEqual(sentence.first?.isUppercase, true, sentence)
        }
    }
}

// MARK: Slow

final class SlowCauseTests: XCTestCase {
    private let usual = PhaseTimings(lookup: 12, connect: 20, secure: 45, wait: 180)

    func testWithHistoryThePhaseThatGrewIsNamedAgainstItsUsual() {
        let history = [PhaseTimings](repeating: usual, count: 20)
        let waiting = Diagnosis.slow(PhaseTimings(lookup: 14, connect: 22, secure: 50, wait: 1600), history: history)
        XCTAssertEqual(waiting, Cause(.phaseGrew, "Waiting for the server took 1.6 s, usually 180 ms."))
        XCTAssertEqual(Diagnosis.slow(PhaseTimings(lookup: 2400, connect: 20, secure: 45, wait: 190), history: history)?.sentence,
                       "Looking up the name took 2.4 s, usually 12 ms.")
        XCTAssertEqual(Diagnosis.slow(PhaseTimings(lookup: 12, connect: 900, secure: 45, wait: 190), history: history)?.sentence, "Connecting took 900 ms, usually 20 ms.")
        XCTAssertEqual(Diagnosis.slow(PhaseTimings(lookup: 12, connect: 20, secure: 1200, wait: 190), history: history)?.sentence,
                       "The secure handshake took 1.2 s, usually 45 ms.")
    }

    func testTheDownloadWhenItIsMeasured() {
        let reading = PhaseTimings(lookup: 12, connect: 20, secure: 45, wait: 180, download: 60)
        let history = [PhaseTimings](repeating: reading, count: 20)
        XCTAssertEqual(Diagnosis.slow(PhaseTimings(lookup: 12, connect: 20, secure: 45, wait: 180, download: 2100), history: history)?.sentence,
                       "Downloading the page took 2.1 s, usually 60 ms.")
    }

    func testEverythingAlittleSlowerNamesNothing() {
        let history = [PhaseTimings](repeating: usual, count: 20)
        // Each phase half as slow again: no one of them is the reason.
        XCTAssertNil(Diagnosis.slow(PhaseTimings(lookup: 100, connect: 110, secure: 135, wait: 270), history: history))
        // Grown, but not by enough to be worth a sentence.
        XCTAssertNil(Diagnosis.slow(PhaseTimings(lookup: 12, connect: 20, secure: 45, wait: 240), history: history))
    }

    func testWithoutHistoryOnlyThePhaseThatTookMostIsNamed() {
        let reading = PhaseTimings(lookup: 14, connect: 22, secure: 50, wait: 1600)
        XCTAssertEqual(Diagnosis.slow(reading, history: []), Cause(.phaseMost, "Most of the time went on waiting for the server (1.6 s)."))
        // Too few earlier readings to say "usually".
        XCTAssertEqual(Diagnosis.slow(reading, history: [PhaseTimings](repeating: usual, count: 11))?.kind, .phaseMost)
        XCTAssertEqual(Diagnosis.slow(reading, history: [PhaseTimings](repeating: usual, count: 12))?.kind, .phaseGrew)
        // Old samples have no phases at all.
        XCTAssertEqual(Diagnosis.slow(reading, history: [PhaseTimings](repeating: PhaseTimings(), count: 30))?.kind, .phaseMost)
        // No phase took most of it: nothing is singled out.
        XCTAssertNil(Diagnosis.slow(PhaseTimings(lookup: 300, connect: 300, secure: 300, wait: 300), history: []))
    }

    func testNoTimingsNoCause() {
        XCTAssertNil(Diagnosis.slow(nil, history: []))
        XCTAssertNil(Diagnosis.slow(PhaseTimings(), history: []))
    }

    func testTheSlowEventCarriesItsCause() {
        // A day of steady pulses with their phases, then two slow ones.
        var history: [Sample] = []
        for index in 0..<40 {
            history.append(Sample(date: start.addingTimeInterval(Double(index - 40) * 300), status: 200, milliseconds: 260, phases: usual))
        }
        var state = SiteState()
        var events: [SiteEvent] = []
        for step in 0..<2 {
            let slow = PulseResult(status: 200, milliseconds: 1700, phases: PhaseTimings(lookup: 14, connect: 22, secure: 50, wait: 1600))
            let now = start.addingTimeInterval(Double(step) * 300)
            let folded = Detector.afterPulse(site: site, state: state, result: slow, history: history, now: now)
            state = folded.state
            events += folded.events
            history.append(Sample(date: now, status: 200, milliseconds: 1700, phases: slow.phases))
        }
        XCTAssertEqual(events.map(\.kind), [.slow])
        XCTAssertEqual(events.first?.cause, "Waiting for the server took 1.6 s, usually 180 ms.")
        XCTAssertEqual(events.first?.full, "acme-rockets.com is slow: it took 1.7 s and usually takes 260 ms. Waiting for the server took 1.6 s, usually 180 ms.")
    }

    func testPhasesAreKeptInFiveShortKeys() throws {
        let data = try JSONEncoder().encode(PhaseTimings(lookup: 1, connect: 2, secure: 3, wait: 4, download: 5))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Int])
        XCTAssertEqual(keys, ["d": 1, "c": 2, "s": 3, "w": 4, "l": 5])
    }
}

// MARK: Must contain and drift

final class ChangeCauseTests: XCTestCase {
    func testAMissingPhraseSaysWhatThePageIsNow() {
        XCTAssertEqual(Diagnosis.missingPhrase(host: "lumen-bikes.com", finalURL: "https://lumen-bikes.com/", body: "<html><head><TITLE>\n 502 Bad   Gateway </TITLE></head>"),
                       Cause(.pageChanged, "The page's title is now “502 Bad Gateway”."))
        XCTAssertEqual(Diagnosis.missingPhrase(host: "lumen-bikes.com", finalURL: "https://login.example.org/sso", body: "<title>Sign in</title>"),
                       Cause(.redirectElsewhere, "The home page now redirects to login.example.org."))
        XCTAssertEqual(Diagnosis.missingPhrase(host: "lumen-bikes.com", finalURL: "https://www.lumen-bikes.com/", body: "<title>Shop &amp; Ride</title>")?.sentence,
                       "The page's title is now “Shop & Ride”.")
        // No title, nothing to say.
        XCTAssertNil(Diagnosis.missingPhrase(host: "lumen-bikes.com", finalURL: nil, body: "<h1>Oops</h1>"))
        XCTAssertNil(Diagnosis.missingPhrase(host: "lumen-bikes.com", finalURL: nil, body: "<title></title>"))
        XCTAssertNil(Diagnosis.missingPhrase(host: "lumen-bikes.com", finalURL: nil, body: nil))
    }

    func testALongTitleIsCut() {
        let title = Diagnosis.title(of: "<title>\(String(repeating: "word ", count: 40))</title>")
        XCTAssertEqual(title?.count, 70)
    }

    func testDriftSaysWhatItWasBefore() {
        func page(_ title: String, _ canonical: String) -> PageSummary {
            PageSummary(url: "https://acme-rockets.com/", status: 200, title: title, canonical: canonical, indexable: true)
        }
        func report(_ page: PageSummary) -> Report {
            Report(site: "https://acme-rockets.com/", date: start, pagesChecked: 1, pagesFound: 1, linksChecked: 1, seconds: 1, findings: [],
                   passed: Check.all.map(\.id), pages: [page])
        }
        let folded = Detector.afterAudit(site: site, state: SiteState(), previous: report(page("Acme Rockets", "https://acme-rockets.com/")),
                                         current: report(page("Coming soon", "https://staging.acme-rockets.com/")), now: start)
        let title = folded.events.first { $0.kind == .titleChanged }
        XCTAssertEqual(title?.full, "The home page title of acme-rockets.com changed to “Coming soon”. It was “Acme Rockets”.")
        let canonical = folded.events.first { $0.kind == .canonicalChanged }
        XCTAssertEqual(canonical?.cause, "It pointed to https://acme-rockets.com/.")
    }
}

// MARK: Diagnosis, through the watcher

final class DiagnosisWatcherTests: XCTestCase {
    private var directory: URL!
    private var pulser: StubPulser!
    private var sideDoor: StubSideDoor!
    private var clock: TestClock!
    private let fine = PulseResult(status: 200, milliseconds: 200)

    override func setUp() {
        directory = scratch()
        pulser = StubPulser()
        sideDoor = StubSideDoor()
        clock = TestClock(start)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func watcher() -> Watcher {
        let clock = self.clock!
        return Watcher(store: Store(directory: directory), pulser: pulser, auditor: StubAuditor(), domains: StubDomains(), sideDoor: sideDoor, clock: { clock.now })
    }

    /// Adds the site, then fails it twice with the same answer. Returns what the second failure raised.
    private func down(with failing: PulseResult) async -> [SiteEvent] {
        let watcher = watcher()
        pulser.queue("acme-rockets.com", fine, failing)
        guard case .added = await watcher.add("acme-rockets.com") else { return [] }
        XCTAssertEqual(sideDoor.asked, [], "nothing extra while the site is fine")
        clock.advance(300)
        let first = await watcher.pulseDue()
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(sideDoor.asked, [], "nor on a first failure that may be a blip")
        clock.advance(30)
        return await watcher.pulseDue().events
    }

    func testAnErrorOnlyOnTheHomePageAsksTwoShortQuestionsAndSaysSo() async {
        sideDoor.answer("/robots.txt", 200)
        let events = await down(with: PulseResult(status: 500, milliseconds: 90, headers: ["server": "nginx"], sample: "<h1>Internal Server Error</h1>"))
        XCTAssertEqual(events.map(\.full), ["acme-rockets.com is down: it answered with error 500. The server is up, the home page is failing: robots.txt still answers."])
        XCTAssertEqual(sideDoor.asked.sorted(), ["/favicon.ico", "/robots.txt"], "two extra requests, and no more")

        // Still down at the next checks: said once, asked once.
        let watcher = watcher()
        clock.advance(300)
        let later = await watcher.pulseDue()
        XCTAssertTrue(later.events.isEmpty)
        XCTAssertEqual(sideDoor.asked.count, 2)
        let kept = await watcher.events.first { $0.kind == .down }
        XCTAssertEqual(kept?.cause, "The server is up, the home page is failing: robots.txt still answers.", "the cause is kept with the event")
    }

    func testTheIconAnswersWhenRobotsDoesNot() async {
        sideDoor.answer("/robots.txt", 404)
        sideDoor.answer("/favicon.ico", 200)
        let events = await down(with: PulseResult(status: 503, milliseconds: 90))
        XCTAssertEqual(events.first?.cause, "The server is up, the home page is failing: favicon.ico still answers.")
    }

    func testNothingElseAnswersSoTheEventFallsBackToWhatTheCodeMeans() async {
        let events = await down(with: PulseResult(status: 503, milliseconds: 90))
        XCTAssertEqual(events.first?.cause, "Error 503 usually means the server is overloaded or in maintenance.")
    }

    func testAFailureTheSideDoorCannotExplainAsksNothing() async {
        let events = await down(with: PulseResult(status: 0, error: "the address does not exist", failure: .nameNotFound))
        XCTAssertEqual(events.map(\.full), ["acme-rockets.com is down: the address does not exist. The name does not resolve, so the trouble is with DNS or the domain and not with the server."])
        XCTAssertEqual(sideDoor.asked, [])
    }

    func testAPlatformsOwnExplanationAsksNothing() async {
        let events = await down(with: PulseResult(status: 522, milliseconds: 90, headers: ["cf-ray": "8e1a-LHR", "server": "cloudflare"]))
        XCTAssertEqual(events.first?.cause, "Cloudflare is up but the server behind it did not answer in time (error 522), so the trouble is at the host and not at Cloudflare.")
        XCTAssertEqual(sideDoor.asked, [])
    }

    func testWithNothingToGoOnTheEventIsPlain() async {
        let events = await down(with: PulseResult(status: 0, error: "it did not answer", failure: .other))
        XCTAssertEqual(events.map(\.full), ["acme-rockets.com is down: it did not answer."])
        XCTAssertNil(events.first?.cause)
    }

    func testPhasesAreStoredWithEachSampleFromNowOn() async {
        let watcher = watcher()
        let timed = PulseResult(status: 200, milliseconds: 260, phases: PhaseTimings(lookup: 12, connect: 20, secure: 45, wait: 180))
        pulser.queue("acme-rockets.com", timed)
        guard case .added(let added) = await watcher.add("acme-rockets.com") else { return XCTFail("not added") }
        clock.advance(300)
        _ = await watcher.pulseDue()
        let kept = Store(directory: directory).samples(for: added.id)
        XCTAssertEqual(kept.map(\.phases), [timed.phases, timed.phases])
    }
}

// MARK: Reading a failed request

final class PulseFailureTests: XCTestCase {
    func testEveryFailureHasAKind() {
        XCTAssertEqual(URLSessionPulser.failure(.cannotFindHost), .nameNotFound)
        XCTAssertEqual(URLSessionPulser.failure(.dnsLookupFailed), .nameNotFound)
        XCTAssertEqual(URLSessionPulser.failure(.timedOut), .timedOut)
        XCTAssertEqual(URLSessionPulser.failure(.cannotConnectToHost), .refused)
        XCTAssertEqual(URLSessionPulser.failure(.networkConnectionLost), .dropped)
        XCTAssertEqual(URLSessionPulser.failure(.serverCertificateUntrusted), .certificate(nil))
        XCTAssertEqual(URLSessionPulser.failure(.serverCertificateHasBadDate), .certificate(nil))
        XCTAssertEqual(URLSessionPulser.failure(.httpTooManyRedirects), .redirectLoop)
        XCTAssertEqual(URLSessionPulser.failure(.badServerResponse), .other)
        XCTAssertEqual(URLSessionPulser.failure(nil), .other)
    }
}

// MARK: Issues

final class IssueTests: XCTestCase {
    private func found() -> Report {
        func url(_ path: String) -> URL { URL(string: "https://acme-rockets.com" + path)! }
        var findings = [
            Finding("description.missing", url: url("/about")),
            Finding("page.noindex", url: url("/pricing"), detail: "meta robots: noindex"),
            Finding("page.noindex", url: url("/launch"), detail: "meta robots: noindex"),
            Finding("sitemap.undeclared", url: url("/robots.txt")),
            Finding("sitemap.offsite", detail: "https://staging.example.net/a"),
        ]
        for index in 1...25 { findings.append(Finding("links.internal", url: url("/blog/\(index)"), detail: "links to /gone_\(index)")) }
        let failed = Set(findings.map(\.check))
        return Report(site: "https://acme-rockets.com/", date: Date(timeIntervalSince1970: 1_799_539_200), pagesChecked: 25, pagesFound: 25, linksChecked: 40, seconds: 2,
                      findings: findings, passed: Check.all.map(\.id).filter { !failed.contains($0) })
    }

    func testMostSeriousFirstWithTheirPagesAndPlaces() {
        let list = IssueList(found())
        XCTAssertEqual(list.host, "acme-rockets.com")
        XCTAssertEqual(list.pagesChecked, 25)
        XCTAssertEqual(list.issues.map(\.id), ["page.noindex", "sitemap.offsite", "links.internal", "description.missing", "sitemap.undeclared"])
        XCTAssertEqual(list.issues.map(\.severity), [.error, .error, .error, .warning, .notice])
        XCTAssertEqual(list.tally, "3 to fix first, 1 to tidy, 1 worth a look")

        let noindex = list.issues[0]
        XCTAssertEqual(noindex.title, "Pages are set to noindex")
        XCTAssertEqual(noindex.pages, 2)
        XCTAssertEqual(noindex.extent, "2 pages")
        XCTAssertEqual(noindex.doneWhen, "No page is hidden from search engines")
        XCTAssertFalse(noindex.why.isEmpty)
        XCTAssertEqual(noindex.places, ["/pricing  meta robots: noindex", "/launch  meta robots: noindex"])
        XCTAssertEqual(noindex.level, .critical)
        XCTAssertEqual(noindex.severityLabel, "Fix before launch")

        // About the site as a whole, not a page.
        XCTAssertEqual(list.issues[1].extent, "Whole site")
        XCTAssertEqual(list.issues[3].extent, "1 page")
        XCTAssertEqual(list.issues[3].level, .warning)
        XCTAssertNil(list.issues[4].level)

        // Only the first few addresses are shown; the rest are counted.
        let links = list.issues[2]
        XCTAssertEqual(links.firstPlaces.shown.count, 3)
        XCTAssertEqual(links.firstPlaces.more, 22)
        XCTAssertEqual(noindex.firstPlaces.more, 0)
    }

    func testACleanAudit() {
        let clean = Report(site: "https://acme-rockets.com/", date: start, pagesChecked: 3, pagesFound: 3, linksChecked: 4, seconds: 1, findings: [], passed: Check.all.map(\.id))
        let list = IssueList(clean)
        XCTAssertTrue(list.issues.isEmpty)
        XCTAssertEqual(list.tally, "Nothing to fix")
        XCTAssertEqual(list.score, 100)
        XCTAssertEqual(list.markdown, """
        # Issues on acme-rockets.com

        Score 100 of 100. 3 pages checked on 15 Jan 2027.

        Nothing to fix: the last audit found no issues.

        """)
    }

    func testMarkdown() {
        let report = found()
        let text = IssueList(report).markdown
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(4)), ["# Issues on acme-rockets.com", "", "Score \(report.score) of 100. 25 pages checked on 10 Jan 2027.", ""])
        XCTAssertEqual(lines.filter { $0.hasPrefix("## ") }, ["## Fix before launch", "## Should fix", "## Worth a look"])
        XCTAssertEqual(lines.filter { $0.hasPrefix("### ") }, [
            "### Pages are set to noindex (2 pages)", "### Sitemap lists pages on another domain (whole site)", "### Broken links between pages (25 pages)",
            "### Pages have no meta description (1 page)", "### robots.txt does not name the sitemap (1 page)",
        ])
        XCTAssertTrue(text.contains("""
        ### Pages are set to noindex (2 pages)

        A noindex tag or header tells search engines to drop the page. It is often left on from staging.

        Done when: No page is hidden from search engines.

        - /pricing  meta robots: noindex
        - /launch  meta robots: noindex

        """))
        // A long list is cut, and says by how much. Characters Markdown would read as markup are escaped.
        XCTAssertTrue(text.contains("- /blog/20  links to /gone\\_20\n- and 5 more\n"))
        XCTAssertFalse(text.contains("/blog/21"))
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
        XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}"))
    }

    func testTheListIsReadFromTheReportKeptOnDiskSoItSurvivesARestart() async {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pulser = StubPulser()
        let auditor = StubAuditor()
        pulser.queue("acme-rockets.com", PulseResult(status: 200, milliseconds: 200))
        auditor.queue(found())
        func watcher() -> Watcher {
            Watcher(store: Store(directory: directory), pulser: pulser, auditor: auditor, domains: StubDomains(), sideDoor: StubSideDoor(), clock: { start })
        }
        var watching = watcher()
        guard case .added(let added) = await watching.add("acme-rockets.com") else { return XCTFail("not added") }
        var list = await watching.issues(for: added.id)
        XCTAssertNil(list, "before the first audit there is nothing to show")
        _ = await watching.audit(added.id)

        watching = watcher()                          // quit and opened again
        list = await watching.issues(for: added.id)
        XCTAssertEqual(list?.issues.count, 5)
        XCTAssertEqual(list?.count(.error), 3)
        let blockers = await watching.entries.first?.state.blockers
        XCTAssertEqual(blockers, list?.count(.error), "the row's \"things to fix first\" and the list agree")
    }
}

// MARK: With and without Launchcheck

final class ReportOfferTests: XCTestCase {
    private struct Installed: SchemeChecking {
        let yes: Bool
        func hasApp(for url: URL) -> Bool { yes && url.scheme == "launchcheck" }
    }

    func testOpenReportWhenLaunchcheckIsInstalledOtherwiseAQuietWordThatItExists() {
        XCTAssertEqual(ReportOffer.of(Installed(yes: true)), .openReport)
        XCTAssertEqual(ReportOffer.of(Installed(yes: false)), .getLaunchcheck)
    }

    func testWhereItIsAndWhatItAdds() {
        XCTAssertEqual(ReportOffer.download.absoluteString, "https://github.com/brijraj-rana/launchcheck/releases/latest")
        XCTAssertEqual(ReportOffer.pitch, "Launchcheck adds the full report, page by page.")
    }

    func testTheIssueListNeedsNothingButTheReport() {
        // No scheme checker, no link, no other app anywhere in sight: a report goes in and the list comes out.
        let report = Report(site: "https://acme-rockets.com/", date: start, pagesChecked: 1, pagesFound: 1, linksChecked: 0, seconds: 1,
                            findings: [Finding("title.missing", url: URL(string: "https://acme-rockets.com/"))], passed: [])
        XCTAssertEqual(IssueList(report).issues.map(\.title), ["Pages have no title"])
    }
}

// MARK: Voice

final class NewWordsTests: XCTestCase {
    func testNoDashesOrExclamationMarksInAnyNewMessage() {
        var texts: [String] = []
        let shop = Site(url: "https://lumen-bikes.com/", host: "lumen-bikes.com", added: start, mustContain: "Add to cart")
        var state = SiteState()
        for index in 0..<3 {
            let folded = Detector.afterPulse(site: shop, state: state, result: PulseResult(status: 200, milliseconds: 200, body: index == 2 ? "Add to cart" : "<title>Oops</title>"),
                                             history: [], now: start.addingTimeInterval(Double(index) * 300))
            state = folded.state
            texts += folded.events.flatMap { [$0.message, $0.brief, $0.full] }
        }
        var domain = SiteState()
        for days in [29.0, 6.0, -1.0] {
            let folded = Detector.afterDomain(site: site, state: domain, domain: "acme-rockets.com", expiry: start.addingTimeInterval(days * day), now: start)
            domain = folded.state
            texts += folded.events.flatMap { [$0.message, $0.brief] }
        }
        texts += PauseLength.allCases.map(\.title)
        texts += [Words.paused(until: nil, now: start), Webhook.Message.test(now: start).text, Webhook.unreachable, ReportOffer.pitch]
        texts += [401, 404, 429, 500].compactMap(Webhook.problem)
        XCTAssertEqual(texts.count, 23, "every event above fired")
        for text in texts {
            XCTAssertFalse(text.contains("\u{2014}") || text.contains("\u{2013}") || text.contains("!"), text)
        }
    }
}
