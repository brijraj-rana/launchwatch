import Foundation
import LaunchcheckCore

/// Decides what is worth telling a person. Pure: the same inputs always give the same events.
public enum Detector {
    /// Failed pulses in a row before a site is called down, so one dropped request alarms nobody.
    public static let failuresBeforeDown = 2
    /// Pulses needed in the last day before "slow" can be judged at all.
    public static let samplesBeforeSlow = 12
    /// Slow pulses in a row before saying so.
    public static let slowPulsesBeforeSlow = 2
    public static let scoreDrop = 5
    /// Checks in a row without the phrase before saying so, so one odd answer alarms nobody.
    public static let missesBeforeMissing = 2

    /// Slow is relative to the site's own habits: three times its median, and at least 400 ms over it.
    public static func slowThreshold(median: Int) -> Int {
        max(median * 3, median + 400)
    }

    /// Back to normal once it is within one and a half times the median again.
    static func calmThreshold(median: Int) -> Int {
        max(median * 3 / 2, median + 150)
    }

    // MARK: Pulse

    /// Folds one pulse into what is known about a site. `history` is the pulses before this one.
    public static func afterPulse(site: Site, state: SiteState, result: PulseResult, history: [Sample], now: Date) -> (state: SiteState, events: [SiteEvent]) {
        var state = state
        var events: [SiteEvent] = []
        func emit(_ kind: EventKind, _ level: Level, _ message: String, _ brief: String, cause: Cause? = nil) {
            events.append(SiteEvent(site: site, kind: kind, level: level, message: message, brief: brief, date: now, cause: cause?.sentence))
        }

        state.lastPulse = now
        if let expiry = result.certificateExpiry { state.certificateExpiry = expiry }

        // Certificate: say so once at each stage, and again only if it gets worse.
        let stage = CertificateStage.of(expiry: state.certificateExpiry, now: now)
        if stage > state.certificateStage, let expiry = state.certificateExpiry {
            switch stage {
            case .expired:
                emit(.certificateExpired, .critical, "The certificate for \(site.host) has expired, so browsers now warn visitors away.",
                     "Certificate expired. Browsers now warn visitors away.")
            case .urgent:
                emit(.certificateUrgent, .critical, "The certificate for \(site.host) \(Words.expiry(expiry, now: now)).",
                     "Certificate \(Words.expiry(expiry, now: now)).")
            case .soon:
                emit(.certificateSoon, .warning, "The certificate for \(site.host) \(Words.expiry(expiry, now: now)).",
                     "Certificate \(Words.expiry(expiry, now: now)).")
            case .fine:
                break
            }
        }
        state.certificateStage = stage

        if result.ok {
            if state.isDown, let since = state.failingSince {
                let length = Words.duration(now.timeIntervalSince(since))
                emit(.recovered, .good, "\(site.host) is back after \(length).", "Back after \(length).")
            }
            state.failures = 0
            state.failingSince = nil
            state.isDown = false
            state.lastError = nil
            state.lastMilliseconds = result.milliseconds

            let usual = Stats.recent(history, now: now, window: 86_400).filter(\.ok).map(\.milliseconds)
            if usual.count >= samplesBeforeSlow, let median = Stats.median(usual) {
                state.slowStreak = result.milliseconds > slowThreshold(median: median) ? state.slowStreak + 1 : 0
                if !state.slow, state.slowStreak >= slowPulsesBeforeSlow {
                    state.slow = true
                    // Where the time went, read off the same request and the same day of history.
                    let phases = Stats.recent(history, now: now, window: 86_400).filter(\.ok).compactMap(\.phases)
                    emit(.slow, .warning, "\(site.host) is slow: it took \(Words.time(result.milliseconds)) and usually takes \(Words.time(median)).",
                         "Slow: \(Words.time(result.milliseconds)), usually \(Words.time(median)).", cause: Diagnosis.slow(result.phases, history: phases))
                } else if state.slow, result.milliseconds <= calmThreshold(median: median) {
                    state.slow = false
                }
            }

            // The phrase: a page that answers but no longer says what it should is an error page with a 200 on it.
            // A pulse that did not read the page says nothing either way.
            if let phrase = Phrase.cleaned(site.mustContain), let body = result.body {
                if Phrase.found(phrase, in: body) {
                    if state.missingPhrase != nil {
                        emit(.phraseBack, .good, "\(site.host) shows “\(phrase)” again.", "Shows “\(phrase)” again.")
                    }
                    state.phraseMisses = 0
                    state.missingPhrase = nil
                } else {
                    let misses = (state.phraseMisses ?? 0) + 1
                    state.phraseMisses = misses
                    if state.missingPhrase == nil, misses >= missesBeforeMissing {
                        state.missingPhrase = phrase
                        emit(.phraseMissing, .critical, "\(site.host) is up but missing “\(phrase)”.", "Up but missing “\(phrase)”.",
                             cause: Diagnosis.missingPhrase(host: site.host, finalURL: result.finalURL, body: body))
                    }
                }
            }
        } else {
            state.failures += 1
            if state.failingSince == nil { state.failingSince = now }
            state.lastError = result.reason
            state.lastMilliseconds = nil
            state.slow = false
            state.slowStreak = 0
            if !state.isDown, state.failures >= failuresBeforeDown {
                state.isDown = true
                // An expired certificate has already been reported in its own words.
                if stage != .expired {
                    // The cause as far as this one answer shows it. The watcher may ask one more question and say more.
                    emit(.down, .critical, "\(site.host) is down: \(result.reason).", "Down: \(result.reason).",
                         cause: Diagnosis.down(DownEvidence(site: site, state: state, result: result, now: now)))
                }
            }
        }
        return (state, events)
    }

    // MARK: Domain

    /// Folds one answer from the registry into what is known about a site. `expiry` is nil when the registry had nothing
    /// to say, and the last date known is kept. Said once at each stage, like the certificate.
    public static func afterDomain(site: Site, state: SiteState, domain: String, expiry: Date?, now: Date) -> (state: SiteState, events: [SiteEvent]) {
        var state = state
        var events: [SiteEvent] = []
        func emit(_ kind: EventKind, _ level: Level, _ message: String, _ brief: String) {
            events.append(SiteEvent(site: site, kind: kind, level: level, message: message, brief: brief, date: now))
        }

        state.domainChecked = now
        if let expiry { state.domainExpiry = expiry }
        let stage = DomainStage.of(expiry: state.domainExpiry, now: now)
        if stage > (state.domainStage ?? .fine), let known = state.domainExpiry {
            switch stage {
            case .expired:
                emit(.domainExpired, .critical, "The domain \(domain) has expired. Renew it before the address stops working.",
                     "Domain expired. Renew it before the address stops working.")
            case .urgent:
                emit(.domainUrgent, .critical, "The domain \(domain) \(Words.expiry(known, now: now)).", "Domain \(Words.expiry(known, now: now)).")
            case .soon:
                emit(.domainSoon, .warning, "The domain \(domain) \(Words.expiry(known, now: now)).", "Domain \(Words.expiry(known, now: now)).")
            case .fine:
                break
            }
        }
        state.domainStage = stage
        return (state, events)
    }

    // MARK: Audit

    /// Folds a finished audit into what is known about a site. Events come only from differences with the audit before it.
    public static func afterAudit(site: Site, state: SiteState, previous: Report?, current: Report, now: Date) -> (state: SiteState, events: [SiteEvent]) {
        var state = state
        var events: [SiteEvent] = []
        func emit(_ kind: EventKind, _ level: Level, _ message: String, _ brief: String, cause: String? = nil) {
            events.append(SiteEvent(site: site, kind: kind, level: level, message: message, brief: brief, date: now, cause: cause))
        }

        let failed = Set(current.findings.map(\.check))
        let home = homePage(of: current)
        state.lastAuditAttempt = now
        state.audited = now
        state.score = current.score
        state.pagesChecked = current.pagesChecked
        state.blockers = current.count(.error)
        state.robotsBlocked = failed.contains("robots.blocks-all")
        state.homeNoindex = home.map { !$0.indexable } ?? false
        state.auditFlag = nil

        guard let previous else { return (state, events) }
        let drift = Drift.compare(previous, current)
        let introduced = Set(drift.introduced.map(\.id))

        // Noindex: pages that were open to search engines last time and are not now.
        let before = Dictionary(previous.pages.map { (key($0.url), $0) }, uniquingKeysWith: { first, _ in first })
        let hidden = current.pages.filter { page in !page.indexable && (before[key(page.url)]?.indexable ?? false) }
        if let first = hidden.first {
            let onHome = hidden.contains { key($0.url) == key(current.site) }
            let place = onHome ? "the home page" : (hidden.count == 1 ? Words.path(of: first.url) : "\(hidden.count) pages")
            emit(.noindex, .critical, "A noindex appeared on \(place) of \(site.host), so search engines will drop \(hidden.count == 1 ? "it" : "them").",
                 "A noindex appeared on \(place).")
        }
        if introduced.contains("robots.blocks-all") {
            emit(.robotsBlocked, .critical, "robots.txt on \(site.host) now blocks every crawler.", "robots.txt now blocks every crawler.")
        }
        if introduced.contains("sitemap.missing") {
            emit(.sitemapGone, .warning, "The sitemap for \(site.host) has disappeared.", "The sitemap has disappeared.")
        }

        if let was = homePage(of: previous), let home {
            let oldTitle = squashed(was.title), newTitle = squashed(home.title)
            if !oldTitle.isEmpty, newTitle.isEmpty {
                emit(.titleChanged, .warning, "The home page of \(site.host) lost its title.", "The home page lost its title.")
            } else if oldTitle != newTitle, !oldTitle.isEmpty {
                emit(.titleChanged, .warning, "The home page title of \(site.host) changed to “\(newTitle)”.", "Home page title changed to “\(newTitle)”.",
                     cause: "It was “\(oldTitle)”.")
            }
            let oldCanonical = was.canonical ?? "", newCanonical = home.canonical ?? ""
            if !oldCanonical.isEmpty, newCanonical.isEmpty {
                emit(.canonicalChanged, .warning, "The home page of \(site.host) lost its canonical tag.", "The home page lost its canonical tag.")
            } else if !oldCanonical.isEmpty, key(oldCanonical) != key(newCanonical) {
                emit(.canonicalChanged, .warning, "The home page canonical of \(site.host) now points to \(newCanonical).", "Home page canonical now points to \(newCanonical).",
                     cause: "It pointed to \(oldCanonical).")
            }
        }

        // Anything else that newly needs fixing. Noindex and robots.txt have been said already.
        let said: Set<String> = ["page.noindex", "robots.blocks-all"]
        for check in drift.introduced where check.severity == .error && !said.contains(check.id) {
            emit(.newProblem, .critical, "New problem on \(site.host): \(lowercasedStart(check.title)).", "New problem: \(lowercasedStart(check.title)).")
        }

        if drift.scoreBefore - drift.scoreAfter >= scoreDrop {
            let causes = drift.introduced.prefix(2).map { lowercasedStart($0.title) }
            let why = causes.isEmpty ? "existing problems now affect more pages" : "new since last time: \(causes.joined(separator: "; "))"
            emit(.scoreDropped, .warning, "The score for \(site.host) fell from \(drift.scoreBefore) to \(drift.scoreAfter), \(why).",
                 "Score fell from \(drift.scoreBefore) to \(drift.scoreAfter), \(why).")
        }

        if let worst = events.min(by: { $0.level < $1.level }) {
            state.auditFlag = AuditFlag(level: worst.level, note: String(worst.brief.dropLast(worst.brief.hasSuffix(".") ? 1 : 0)))
        }
        return (state, events)
    }

    // MARK: Helpers

    static func homePage(of report: Report) -> PageSummary? {
        report.pages.first { key($0.url) == key(report.site) }
    }

    /// One identity per address: lowercased scheme and host, no fragment, no trailing slash.
    static func key(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        return "\(url.scheme?.lowercased() ?? "https")://\(host.lowercased())\(url.port.map { ":\($0)" } ?? "")\(path)\(url.query.map { "?\($0)" } ?? "")"
    }

    private static func squashed(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "Broken links between pages" reads better mid-sentence as "broken links between pages"; "H1" and "robots.txt" stay as they are.
    static func lowercasedStart(_ title: String) -> String {
        guard let first = title.first, first.isUppercase else { return title }
        let second = title.dropFirst().first
        if let second, second.isUppercase || second.isNumber { return title }
        return first.lowercased() + title.dropFirst()
    }
}

// MARK: Health

/// How a site is doing right now, for its dot, its place in the list and the one quiet line under its name.
public struct Health: Equatable, Sendable {
    public enum Condition: Int, Comparable, Sendable {
        case critical, warning, fine, unknown, paused
        public static func < (a: Condition, b: Condition) -> Bool { a.rawValue < b.rawValue }
    }

    public var condition: Condition
    public var note: String?
    public var isDown = false

    public var needsAttention: Bool { condition == .critical || condition == .warning }

    public static func of(_ state: SiteState, now: Date, calendar: Calendar = .current) -> Health {
        // Paused comes first: whatever was wrong, nobody is looking and nothing is raised.
        if Pausing.isPaused(state, now: now) {
            return Health(condition: .paused, note: Words.paused(until: state.pause?.until, now: now, calendar: calendar))
        }
        guard state.lastPulse != nil else { return Health(condition: .unknown, note: "Not checked yet") }
        if state.certificateStage == .expired {
            return Health(condition: .critical, note: "Certificate has expired", isDown: state.isDown)
        }
        if state.isDown {
            let length = state.failingSince.map { "Down for \(Words.duration(now.timeIntervalSince($0)))" } ?? "Down"
            return Health(condition: .critical, note: length, isDown: true)
        }
        if let phrase = state.missingPhrase {
            return Health(condition: .critical, note: "Up but missing “\(phrase)”")
        }
        if state.certificateStage == .urgent, let expiry = state.certificateExpiry {
            return Health(condition: .critical, note: "Certificate \(Words.expiry(expiry, now: now))")
        }
        if state.domainStage == .expired { return Health(condition: .critical, note: "Domain has expired") }
        if state.domainStage == .urgent, let expiry = state.domainExpiry {
            return Health(condition: .critical, note: "Domain \(Words.expiry(expiry, now: now))")
        }
        if state.robotsBlocked { return Health(condition: .critical, note: "robots.txt blocks every crawler") }
        if state.homeNoindex { return Health(condition: .critical, note: "Home page is set to noindex") }
        if let flag = state.auditFlag, flag.level == .critical { return Health(condition: .critical, note: flag.note) }
        if state.slow { return Health(condition: .warning, note: "Slower than usual") }
        if state.certificateStage == .soon, let expiry = state.certificateExpiry {
            return Health(condition: .warning, note: "Certificate \(Words.expiry(expiry, now: now))")
        }
        if state.domainStage == .soon, let expiry = state.domainExpiry {
            return Health(condition: .warning, note: "Domain \(Words.expiry(expiry, now: now))")
        }
        if let flag = state.auditFlag, flag.level == .warning { return Health(condition: .warning, note: flag.note) }
        return Health(condition: .fine, note: nil)
    }
}

/// Everything the panel shows for one site, worked out once.
public struct SiteSummary: Equatable, Identifiable, Sendable {
    public var site: Site
    public var state: SiteState
    public var health: Health
    public var buckets: [Bucket]
    /// The last week in six hour stretches, oldest first.
    public var strip: [StripCell]
    public var uptime: Double?
    public var median: Int?
    /// The last day of response times, for the open row.
    public var chart: ResponseChart
    /// Newest first.
    public var events: [SiteEvent]

    public var id: UUID { site.id }
    public var isPaused: Bool { health.condition == .paused }

    public init(site: Site, state: SiteState, health: Health, buckets: [Bucket], strip: [StripCell] = [], uptime: Double?, median: Int?,
                chart: ResponseChart = .empty, events: [SiteEvent]) {
        self.site = site
        self.state = state
        self.health = health
        self.buckets = buckets
        self.strip = strip
        self.uptime = uptime
        self.median = median
        self.chart = chart
        self.events = events
    }

    public static func make(_ entry: Entry, samples: [Sample], events: [SiteEvent], now: Date, calendar: Calendar = .current) -> SiteSummary {
        let pauses = Pausing.spans(entry.state, now: now)
        return SiteSummary(site: entry.site, state: entry.state, health: Health.of(entry.state, now: now, calendar: calendar),
                           buckets: Stats.buckets(samples, now: now), strip: Stats.strip(samples, now: now, calendar: calendar, pauses: pauses),
                           uptime: Stats.uptime(samples, now: now, pauses: pauses),
                           median: Stats.medianResponse(samples, now: now),
                           chart: Stats.chart(samples, now: now),
                           events: events.filter { $0.site == entry.site.id }.sorted { $0.date > $1.date })
    }

    /// Sites in trouble first, most serious at the top; the rest in the order they were added; paused ones last.
    public static func sorted(_ summaries: [SiteSummary]) -> [SiteSummary] {
        summaries.enumerated().sorted { a, b in
            let x = rank(a.element.health), y = rank(b.element.health)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    private static func rank(_ health: Health) -> Int {
        switch health.condition {
        case .critical: return health.isDown ? 0 : 1
        case .warning: return 2
        case .fine, .unknown: return 3
        case .paused: return 4
        }
    }

    /// What VoiceOver says for the row.
    public var spoken: String {
        var parts = [site.host]
        switch health.condition {
        case .critical, .warning: parts.append(health.note ?? "needs a look")
        case .fine: parts.append("fine")
        case .unknown: parts.append("not checked yet")
        case .paused: return [site.host, health.note ?? "paused"].joined(separator: ", ")
        }
        if let ms = state.lastMilliseconds, !health.isDown { parts.append("answered in \(Words.time(ms))") }
        if let score = state.score { parts.append("score \(score) of 100") } else { parts.append("not audited yet") }
        return parts.joined(separator: ", ")
    }
}

public enum Verdict {
    /// The one line at the top of the panel.
    /// A paused site is left out of it: it is neither fine nor in trouble, and it is not counted.
    public static func line(_ all: [SiteSummary], offline: Bool) -> String {
        if all.isEmpty { return "Nothing to watch yet" }
        if offline { return "This Mac is offline" }
        let sites = all.filter { !$0.isPaused }
        if sites.isEmpty { return all.count == 1 ? "\(all[0].site.host) is paused" : "All \(all.count) sites are paused" }
        let troubled = sites.filter(\.health.needsAttention)
        let down = troubled.filter(\.health.isDown)
        if troubled.isEmpty {
            if sites.allSatisfy({ $0.health.condition == .unknown }) {
                return sites.count == 1 ? "Checking \(sites[0].site.host)" : "Checking \(sites.count) sites"
            }
            return sites.count == 1 ? "\(sites[0].site.host) is fine" : "All \(sites.count) sites are fine"
        }
        // A site that is down is the headline, whatever else is going on.
        if down.count == 1 { return "\(down[0].site.host) is down" }
        if down.count > 1 { return "\(down.count) sites are down" }
        if troubled.count == 1 { return "\(troubled[0].site.host) needs a look" }
        return "\(troubled.count) sites need a look"
    }
}

// MARK: Must contain

/// Whether a page still says what it should.
public enum Phrase {
    public static let longest = 80

    /// The phrase as it is kept: trimmed, on one line, not too long. Nil when there is nothing left to look for.
    public static func cleaned(_ phrase: String?) -> String? {
        guard let phrase else { return nil }
        let words = phrase.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.isEmpty ? nil : String(words.prefix(longest))
    }

    /// True when the page shows the phrase. Case and spacing do not matter, and the phrase may be broken up by tags
    /// or written with entities: "Add to cart" is found in `<b>Add</b>&nbsp;to cart`.
    public static func found(_ phrase: String, in html: String) -> Bool {
        guard let wanted = cleaned(phrase).map(squash) else { return true }
        // As written first, which also finds a phrase inside an attribute or a script.
        if squash(html).contains(wanted) { return true }
        // Then the words alone. A tag may sit inside a run of words (`<b>Add</b> to cart`) or stand between two (`<span>Add</span><span>to cart</span>`).
        return squash(text(of: html, tagsBecome: "")).contains(wanted) || squash(text(of: html, tagsBecome: " ")).contains(wanted)
    }

    /// Lowercased, with every run of whitespace as one space.
    static func squash(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let entities: [(String, String)] = [
        ("&nbsp;", " "), ("&#160;", " "), ("&#xa0;", " "), ("&quot;", "\""), ("&#34;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
        ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"),
    ]

    /// The words of a page without its tags, with the entities people actually type turned back into characters.
    static func text(of html: String, tagsBecome gap: String) -> String {
        var out = ""
        out.reserveCapacity(html.count)
        var inTag = false
        for character in html {
            if character == "<" {
                inTag = true
            } else if character == ">" {
                if inTag { out += gap }
                inTag = false
            } else if !inTag {
                out.append(character == "\u{a0}" ? " " : character)
            }
        }
        for (entity, plain) in entities {
            out = out.replacingOccurrences(of: entity, with: plain, options: .caseInsensitive)
        }
        return out
    }
}
