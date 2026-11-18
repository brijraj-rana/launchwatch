import AppKit
import LaunchwatchCore
import SwiftUI

/// In README images Launchcheck is always installed, whatever is on the Mac that renders them.
private struct Pretend: SchemeChecking {
    var installed = true
    func hasApp(for url: URL) -> Bool { installed }
}

/// Development aid: renders the panel to PNGs with made-up sites, so README images never show a real client's.
@MainActor
enum Snapshot {
    static func render(to directory: String, scale: CGFloat) {
        let out = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (name, model) in scenes() {
                let view = PanelView(model: model)
                    .background(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).fill(Tone.surface)
                        .shadow(color: .black.opacity(dark ? 0.5 : 0.2), radius: 22, y: 10))
                    .padding(40)
                write(view, to: out.appendingPathComponent(dark ? "\(name)-dark.png" : "\(name).png"), dark: dark, scale: scale)
            }
            write(menuBar(dark: dark), to: out.appendingPathComponent(dark ? "menubar-dark.png" : "menubar.png"), dark: dark, scale: scale)
        }
        exit(0)
    }

    private static func write(_ view: some View, to file: URL, dark: Bool, scale: CGFloat) {
        let renderer = ImageRenderer(content: view.environment(\.isSnapshot, true).environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = scale
        if let cg = renderer.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? data.write(to: file)
        }
    }

    /// The menu bar item in its three states: quiet, one site needing a look, several in trouble.
    private static func menuBar(dark: Bool) -> some View {
        func item(_ color: Color?, _ count: Int?) -> some View {
            HStack(spacing: 3) {
                Image(nsImage: Glyph.image()).renderingMode(.template)
                    .overlay(alignment: .topTrailing) {
                        if let color { Circle().fill(color).frame(width: 6, height: 6).offset(x: 1.5, y: 1) }
                    }
                if let count { Text("\(count)").font(.system(size: 12, weight: .medium)).monospacedDigit() }
            }
        }
        return HStack(spacing: 22) {
            item(nil, nil)
            item(Tone.warning, nil)
            item(Tone.critical, 2)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: 26)
        .background(dark ? Color(white: 0.16) : Color(white: 0.93))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(12)
    }

    // MARK: Made-up sites

    private static let now = Date()

    /// A believable day of response times: steady, a little noisy, with whatever went wrong.
    private static func day(around base: Int, seed: UInt64, spike: Range<Int>? = nil, down: Range<Int>? = nil, from first: Int = 0, to last: Int = 48) -> [Bucket] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func noise() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 1000) / 1000
        }
        var drift = 0.0
        return (0..<48).map { index in
            let jitter = noise()
            // Half-hour averages wander slowly; they do not jump about.
            drift = drift * 0.75 + (jitter - 0.5) * 0.22
            if index < first || index >= last { return .empty }
            if let down, down.contains(index) { return .down }
            var ms = Double(base) * (1 + drift)
            if let spike, spike.contains(index) { ms *= 2.2 + jitter * 0.6 }
            return .up(Int(ms))
        }
    }

    /// A week in six hour stretches. The Mac slept through one night, so nothing was checked then.
    private static func week(down: Set<Int> = [], asleep: Set<Int> = [9, 10], paused: Set<Int> = [], from first: Int = 0) -> [StripCell] {
        Stats.strip([], now: now).enumerated().map { index, cell in
            let state: StripCell.State = index < first || asleep.contains(index) ? .empty
                : (paused.contains(index) ? .paused : (down.contains(index) ? .down : .up))
            return StripCell(state: state, start: cell.start, end: cell.end)
        }
    }

    /// The same day at twice the detail, for the chart in the open row: each half hour becomes two quarters that differ a little.
    private static func fine(_ buckets: [Bucket], seed: UInt64) -> ResponseChart {
        var state = seed &* 2862933555777941757 &+ 3037000493
        var cells: [Bucket] = []
        for bucket in buckets {
            for _ in 0..<2 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let nudge = 0.97 + Double((state >> 33) % 1000) / 1000 * 0.06
                if case .up(let ms) = bucket { cells.append(.up(Int(Double(ms) * nudge))) } else { cells.append(bucket) }
            }
        }
        let times = cells.compactMap { cell -> Int? in
            if case .up(let ms) = cell { return ms }
            return nil
        }
        return ResponseChart(buckets: cells, median: Stats.median(times), slowest: times.max(), fastest: times.min())
    }

    /// 24-hour times in the images, whatever the Mac that renders them prefers.
    private static let calendar: Calendar = {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    /// The next full hour that is at least half an hour away: where a one hour pause might end.
    private static let pauseEnd: Date = {
        let later = now.addingTimeInterval(90.0 * 60)
        return calendar.dateInterval(of: .hour, for: later)?.start ?? later
    }()

    private static func site(_ host: String, score: Int?, ms: Int, seed: UInt64, uptime: Double = 1, certificateDays: Double = 61,
                             domainDays: Double = 212, mustContain: String? = nil,
                             buckets: [Bucket]? = nil, strip: [StripCell]? = nil, events: [(EventKind, Level, String, TimeInterval)] = [],
                             causes: [EventKind: String] = [:], _ change: (inout SiteState) -> Void = { _ in }) -> SiteSummary {
        let site = Site(url: "https://\(host)/", host: host, added: now.addingTimeInterval(-30 * 86_400), mustContain: mustContain)
        var state = SiteState()
        state.lastPulse = now.addingTimeInterval(-140)
        state.lastMilliseconds = ms
        state.certificateExpiry = now.addingTimeInterval(certificateDays * 86_400)
        state.certificateStage = CertificateStage.of(expiry: state.certificateExpiry, now: now)
        state.domainChecked = now.addingTimeInterval(-5.5 * 3600)
        state.domainExpiry = now.addingTimeInterval(domainDays * 86_400)
        state.domainStage = DomainStage.of(expiry: state.domainExpiry, now: now)
        if mustContain != nil { state.phraseMisses = 0 }
        state.score = score
        if score != nil {
            state.audited = now.addingTimeInterval(-3.2 * 3600)
            state.pagesChecked = 25
        }
        change(&state)
        let log = events.map { SiteEvent(site: site, kind: $0.0, level: $0.1, message: $0.2, brief: $0.2, date: now.addingTimeInterval(-$0.3), cause: causes[$0.0]) }
        let drawn = buckets ?? day(around: ms, seed: seed)
        return SiteSummary(site: site, state: state, health: Health.of(state, now: now, calendar: calendar), buckets: drawn,
                           strip: strip ?? week(), uptime: uptime, median: ms, chart: fine(drawn, seed: seed), events: log)
    }

    private static func healthy() -> [SiteSummary] {
        [
            site("acme-rockets.com", score: 92, ms: 240, seed: 3, uptime: 0.9992),
            site("tidyhq.io", score: 100, ms: 130, seed: 7),
            site("northwind-studio.com", score: 98, ms: 310, seed: 11, buckets: day(around: 310, seed: 11, spike: 30..<33)),
            site("harbour-coffee.co", score: 81, ms: 420, seed: 19),
            site("fieldnotes.studio", score: 95, ms: 180, seed: 23),
            site("lumen-bikes.com", score: 88, ms: 270, seed: 29, domainDays: 143, mustContain: "Add to cart"),
        ]
    }

    /// The same six, with one of them paused for an hour while it is being worked on.
    private static func withOnePaused() -> [SiteSummary] {
        var sites = healthy()
        sites[4] = site("fieldnotes.studio", score: 95, ms: 180, seed: 23, buckets: day(around: 180, seed: 23, to: 47), strip: week(paused: [27])) {
            $0.pause = Pause(since: now.addingTimeInterval(-24.0 * 60), until: pauseEnd)
        }
        return SiteSummary.sorted(sites)
    }

    /// One site that answers, but with the wrong page.
    private static func missingPhrase() -> [SiteSummary] {
        var sites = troubled().filter { $0.site.host != "acme-rockets.com" }
        guard let index = sites.firstIndex(where: { $0.site.host == "lumen-bikes.com" }) else { return sites }
        sites[index] = site("lumen-bikes.com", score: 88, ms: 270, seed: 29, domainDays: 143, mustContain: "Add to cart",
                            events: [(.phraseMissing, .critical, "Up but missing “Add to cart”.", 7.0 * 60)]) {
            $0.phraseMisses = 2
            $0.missingPhrase = "Add to cart"
        }
        return SiteSummary.sorted(sites)
    }

    private static func troubled() -> [SiteSummary] {
        var sites = healthy()
        sites[0] = site("acme-rockets.com", score: 77, ms: 240, seed: 3, uptime: 0.9871,
                        buckets: day(around: 240, seed: 3, spike: 37..<40, down: 46..<48), strip: week(down: [15, 27]),
                        events: [
                            (.down, .critical, "Down: it answered with error 502.", 12.0 * 60),
                            (.slow, .warning, "Slow: 1.9 s, usually 240 ms.", 4.6 * 3600),
                            (.scoreDropped, .warning, "Score fell from 85 to 77, new since last time: pages are set to noindex.", 27.0 * 3600),
                            (.recovered, .good, "Back after 6 minutes.", 3.0 * 86_400),
                        ],
                        causes: [
                            .down: "The server is up, the home page is failing: robots.txt still answers.",
                            .slow: "Waiting for the server took 1.6 s, usually 180 ms.",
                        ]) {
            $0.isDown = true
            $0.failures = 3
            $0.failingSince = now.addingTimeInterval(-12 * 60)
            $0.lastMilliseconds = nil
            $0.blockers = 3
        }
        sites[3] = site("harbour-coffee.co", score: 81, ms: 420, seed: 19, certificateDays: 9.4,
                        events: [(.certificateSoon, .warning, "Certificate expires in 14 days.", 4.6 * 86_400)])
        return SiteSummary.sorted(sites)
    }

    /// What an audit of the first site might have found.
    private static let found = IssueList(host: "acme-rockets.com", date: now.addingTimeInterval(-3.2 * 3600), score: 77, pagesChecked: 25, issues: [
        Issue(id: "page.noindex", severity: .error, title: "Pages are set to noindex",
              why: "A noindex tag or header tells search engines to drop the page. It is often left on from staging.",
              doneWhen: "No page is hidden from search engines", pages: 4,
              places: ["/pricing  meta robots: noindex", "/pricing/teams  meta robots: noindex", "/launch  meta robots: noindex", "/launch/press  meta robots: noindex"]),
        Issue(id: "links.internal", severity: .error, title: "Broken links between pages",
              why: "These links go to pages on this site that do not load.", doneWhen: "No broken links between pages", pages: 2,
              places: ["/about  links to /team (404)", "/blog/liftoff  links to /press-kit (404)"]),
        Issue(id: "title.missing", severity: .error, title: "Pages have no title",
              why: "The title is the headline of a search result. Without one, search engines make something up.",
              doneWhen: "Every page has a title", pages: 1, places: ["/launch/press"]),
        Issue(id: "description.missing", severity: .warning, title: "Pages have no meta description", why: "", doneWhen: "Every page has a meta description",
              pages: 6, places: []),
        Issue(id: "images.alt", severity: .warning, title: "Images have no alt text", why: "", doneWhen: "Every image has an alt attribute", pages: 9, places: []),
        Issue(id: "sitemap.undeclared", severity: .notice, title: "robots.txt does not name the sitemap", why: "", doneWhen: "robots.txt names the sitemap",
              pages: 1, places: []),
    ])

    private static func model(_ sites: [SiteSummary], launchcheck: Bool = true, _ change: (WatchModel) -> Void = { _ in }) -> WatchModel {
        let model = WatchModel(watcher: nil, schemes: Pretend(installed: launchcheck))
        model.sites = sites
        model.now = now
        model.lastChecked = sites.isEmpty ? nil : now.addingTimeInterval(-140)
        change(model)
        return model
    }

    /// A week in which nothing happened, and one in which a few things did.
    private static let quietWeek = WeekSummary(date: now.addingTimeInterval(-26.0 * 3600), sites: 6, uptime: 1)
    private static let busyWeek = WeekSummary(date: now.addingTimeInterval(-26.0 * 3600), sites: 6, uptime: 0.9992, outages: 1,
                                              longest: WeekSummary.LongestOutage(host: "acme-rockets.com", seconds: 6.0 * 60),
                                              certificates: [WeekSummary.Certificate(host: "harbour-coffee.co", expiry: now.addingTimeInterval(9.4 * 86_400))],
                                              scoreDrops: 1)

    private static func scenes() -> [(String, WatchModel)] {
        let troubled = troubled()
        let acme = troubled[0].id
        let calm = healthy()
        let lumen = calm[5].id
        let resting = withOnePaused()
        let fieldnotes = resting.first { $0.isPaused }?.id
        var fresh = healthy()
        fresh.append(site("paperplane.app", score: nil, ms: 210, seed: 31, buckets: day(around: 210, seed: 31, from: 47), strip: week(from: 27)) {
            $0.audited = nil
        })
        return [
            ("fine", model(healthy()) { $0.summary = quietWeek }),
            ("down", model(troubled) { $0.expanded = acme; $0.selected = acme; $0.summary = busyWeek }),
            ("summary", model(troubled) { $0.summary = busyWeek; $0.summaryOpen = true }),
            ("attention", model(troubled.filter { $0.site.host != "acme-rockets.com" })),
            ("settings", model(healthy()) {
                $0.showSettings = true
                $0.summary = quietWeek
                $0.settings.webhook = "https://hooks.slack.com/services/T0ACME/B0WATCH/launchwatch"
                $0.webhookDraft = $0.settings.webhook ?? ""
            }),
            ("detail", model(calm) { $0.expanded = lumen; $0.selected = lumen; $0.summary = quietWeek }),
            ("paused", model(resting) { $0.summary = quietWeek }),
            ("paused-open", model(resting) { $0.expanded = fieldnotes; $0.selected = fieldnotes }),
            ("pausing", model(calm) { $0.expanded = lumen; $0.selected = lumen; $0.pausing = lumen }),
            ("missing", model(missingPhrase())),
            ("issues", model(troubled) { $0.expanded = acme; $0.selected = acme; $0.showingIssues = acme; $0.issues[acme] = found; $0.openIssue = "page.noindex" }),
            ("issues-alone", model(troubled, launchcheck: false) {
                $0.expanded = acme; $0.selected = acme; $0.showingIssues = acme; $0.issues[acme] = found; $0.openIssue = "page.noindex"
            }),
            ("issues-later", model(troubled, launchcheck: false) { $0.expanded = acme; $0.selected = acme; $0.showingIssues = acme }),
            ("checking", model(fresh) { $0.activity = .auditing("paperplane.app"); $0.expanded = fresh[6].id }),
            ("not-added", model(Array(healthy().prefix(3))) {
                $0.draft = "acme-rokets.com"
                $0.addProblem = AddOutcome.noAnswer(host: "acme-rokets.com", status: 0, reason: "the address does not exist").sentence
            }),
            ("offline", model(troubled) { $0.offline = true; $0.lastChecked = now.addingTimeInterval(-12 * 60) }),
            ("empty", model([])),
        ]
    }
}
