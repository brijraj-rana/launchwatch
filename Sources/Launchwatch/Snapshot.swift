import AppKit
import LaunchwatchCore
import SwiftUI

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
    private static func day(around base: Int, seed: UInt64, spike: Range<Int>? = nil, down: Range<Int>? = nil, from first: Int = 0) -> [Bucket] {
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
            if index < first { return .empty }
            if let down, down.contains(index) { return .down }
            var ms = Double(base) * (1 + drift)
            if let spike, spike.contains(index) { ms *= 2.2 + jitter * 0.6 }
            return .up(Int(ms))
        }
    }

    private static func site(_ host: String, score: Int?, ms: Int, seed: UInt64, uptime: Double = 1, certificateDays: Double = 61,
                             buckets: [Bucket]? = nil, events: [(EventKind, Level, String, TimeInterval)] = [],
                             _ change: (inout SiteState) -> Void = { _ in }) -> SiteSummary {
        let site = Site(url: "https://\(host)/", host: host, added: now.addingTimeInterval(-30 * 86_400))
        var state = SiteState()
        state.lastPulse = now.addingTimeInterval(-140)
        state.lastMilliseconds = ms
        state.certificateExpiry = now.addingTimeInterval(certificateDays * 86_400)
        state.certificateStage = CertificateStage.of(expiry: state.certificateExpiry, now: now)
        state.score = score
        if score != nil {
            state.audited = now.addingTimeInterval(-3.2 * 3600)
            state.pagesChecked = 25
        }
        change(&state)
        let log = events.map { SiteEvent(site: site, kind: $0.0, level: $0.1, message: $0.2, brief: $0.2, date: now.addingTimeInterval(-$0.3)) }
        return SiteSummary(site: site, state: state, health: Health.of(state, now: now), buckets: buckets ?? day(around: ms, seed: seed),
                           uptime: uptime, median: ms, events: log)
    }

    private static func healthy() -> [SiteSummary] {
        [
            site("acme-rockets.com", score: 92, ms: 240, seed: 3, uptime: 0.9992),
            site("tidyhq.io", score: 100, ms: 130, seed: 7),
            site("northwind-studio.com", score: 98, ms: 310, seed: 11, buckets: day(around: 310, seed: 11, spike: 30..<33)),
            site("harbour-coffee.co", score: 81, ms: 420, seed: 19),
            site("fieldnotes.studio", score: 95, ms: 180, seed: 23),
            site("lumen-bikes.com", score: 88, ms: 270, seed: 29),
        ]
    }

    private static func troubled() -> [SiteSummary] {
        var sites = healthy()
        sites[0] = site("acme-rockets.com", score: 77, ms: 240, seed: 3, uptime: 0.9871,
                        buckets: day(around: 240, seed: 3, spike: 37..<40, down: 46..<48),
                        events: [
                            (.down, .critical, "Down: the server refused the connection.", 12 * 60),
                            (.slow, .warning, "Slow: 1.9 s, usually 240 ms.", 4.6 * 3600),
                            (.scoreDropped, .warning, "Score fell from 85 to 77, new since last time: pages are set to noindex.", 27 * 3600),
                            (.recovered, .good, "Back after 6 minutes.", 3 * 86_400),
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

    private static func model(_ sites: [SiteSummary], _ change: (WatchModel) -> Void = { _ in }) -> WatchModel {
        let model = WatchModel(watcher: nil)
        model.sites = sites
        model.now = now
        model.lastChecked = sites.isEmpty ? nil : now.addingTimeInterval(-140)
        change(model)
        return model
    }

    private static func scenes() -> [(String, WatchModel)] {
        let troubled = troubled()
        let acme = troubled[0].id
        var fresh = healthy()
        fresh.append(site("paperplane.app", score: nil, ms: 210, seed: 31, buckets: day(around: 210, seed: 31, from: 47)) {
            $0.audited = nil
        })
        return [
            ("fine", model(healthy())),
            ("down", model(troubled) { $0.expanded = acme; $0.selected = acme }),
            ("attention", model(troubled.filter { $0.site.host != "acme-rockets.com" })),
            ("settings", model(healthy()) { $0.showSettings = true }),
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
