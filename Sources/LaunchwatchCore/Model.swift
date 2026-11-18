import Foundation

/// A site being watched.
public struct Site: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The home page, as in "https://example.com/".
    public var url: String
    public var host: String
    public var added: Date
    /// A phrase the home page must show, as in "Add to cart". Nil when nothing is asked of the page.
    public var mustContain: String?

    public init(id: UUID = UUID(), url: String, host: String, added: Date, mustContain: String? = nil) {
        self.id = id
        self.url = url
        self.host = host
        self.added = added
        self.mustContain = mustContain
    }
}

/// What one request to the home page found.
public struct PulseResult: Equatable, Sendable {
    /// The HTTP status, or 0 when there was no answer.
    public var status: Int
    public var milliseconds: Int
    /// Why there was no answer, in words that finish the sentence "it is down: ...".
    public var error: String?
    public var certificateExpiry: Date?
    /// True when the request failed because this Mac has no connection, which says nothing about the site.
    public var offline: Bool
    /// The page itself, read only when the site has a phrase to look for.
    public var body: String?

    // What a diagnosis reads. All of it comes from the same one request.

    /// What kind of failure it was, when there was no answer.
    public var failure: PulseFailure?
    /// The answer's headers, names lowercased.
    public var headers: [String: String]
    /// The start of the page, kept when the answer was an error so its author can be recognised.
    public var sample: String?
    /// Where the request ended up after any redirects.
    public var finalURL: String?
    /// How the time was spent.
    public var phases: PhaseTimings?

    public init(status: Int, milliseconds: Int = 0, error: String? = nil, certificateExpiry: Date? = nil, offline: Bool = false, body: String? = nil,
                failure: PulseFailure? = nil, headers: [String: String] = [:], sample: String? = nil, finalURL: String? = nil, phases: PhaseTimings? = nil) {
        self.status = status
        self.milliseconds = milliseconds
        self.error = error
        self.certificateExpiry = certificateExpiry
        self.offline = offline
        self.body = body
        self.failure = failure
        self.headers = headers
        self.sample = sample
        self.finalURL = finalURL
        self.phases = phases
    }

    public var ok: Bool { (200..<400).contains(status) }

    /// The reason a failed pulse failed.
    public var reason: String {
        if let error { return error }
        return status == 0 ? "it did not answer" : "it answered with error \(status)"
    }
}

/// One pulse, kept for the sparkline and the uptime figure. Short keys, because a week of these is written often.
public struct Sample: Codable, Equatable, Sendable {
    public var date: Date
    public var status: Int
    public var milliseconds: Int
    /// How the time was spent. Missing from samples kept before 0.3.0.
    public var phases: PhaseTimings?

    public init(date: Date, status: Int, milliseconds: Int, phases: PhaseTimings? = nil) {
        self.date = date
        self.status = status
        self.milliseconds = milliseconds
        self.phases = phases
    }

    public var ok: Bool { (200..<400).contains(status) }

    enum CodingKeys: String, CodingKey {
        case date = "t", status = "s", milliseconds = "m", phases = "p"
    }
}

public enum Level: Int, Codable, Comparable, Sendable {
    case critical, warning, good

    public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

public enum EventKind: String, Codable, Sendable {
    case down, recovered, slow
    case certificateSoon, certificateUrgent, certificateExpired
    case domainSoon, domainUrgent, domainExpired
    case phraseMissing, phraseBack
    case noindex, robotsBlocked, sitemapGone, titleChanged, canonicalChanged, newProblem, scoreDropped
}

/// Something worth telling a person.
public struct SiteEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var site: UUID
    public var host: String
    public var kind: EventKind
    public var level: Level
    /// One sentence that stands on its own, for a notification.
    public var message: String
    /// The same thing without the site's name, for a list that already shows it.
    public var brief: String
    public var date: Date
    /// The likely cause, in one sentence, when a diagnosis found one. It adds to the message and never repeats it.
    public var cause: String?

    /// The message with its cause: what a notification and a channel are told.
    public var full: String {
        guard let cause, !cause.isEmpty else { return message }
        return "\(message) \(cause)"
    }

    public init(id: UUID = UUID(), site: Site, kind: EventKind, level: Level, message: String, brief: String, date: Date, cause: String? = nil) {
        self.cause = cause
        self.id = id
        self.site = site.id
        self.host = site.host
        self.kind = kind
        self.level = level
        self.message = message
        self.brief = brief
        self.date = date
    }
}

public enum CertificateStage: Int, Codable, Comparable, Sendable {
    case fine, soon, urgent, expired

    public static let soonDays = 14.0
    public static let urgentDays = 3.0

    public static func < (a: CertificateStage, b: CertificateStage) -> Bool { a.rawValue < b.rawValue }

    public static func of(expiry: Date?, now: Date) -> CertificateStage {
        guard let expiry else { return .fine }
        let days = expiry.timeIntervalSince(now) / 86_400
        if days <= 0 { return .expired }
        if days <= urgentDays { return .urgent }
        if days <= soonDays { return .soon }
        return .fine
    }
}

/// How close a domain's registration is to running out. The same ladder as the certificate, with longer rungs,
/// because renewing a domain can take a person and a payment.
public enum DomainStage: Int, Codable, Comparable, Sendable {
    case fine, soon, urgent, expired

    public static let soonDays = 30.0
    public static let urgentDays = 7.0

    public static func < (a: DomainStage, b: DomainStage) -> Bool { a.rawValue < b.rawValue }

    public static func of(expiry: Date?, now: Date) -> DomainStage {
        guard let expiry else { return .fine }
        let days = expiry.timeIntervalSince(now) / 86_400
        if days <= 0 { return .expired }
        if days <= urgentDays { return .urgent }
        if days <= soonDays { return .soon }
        return .fine
    }
}

/// A stretch when a site is not watched, because its owner said so.
public struct Pause: Codable, Equatable, Sendable {
    public var since: Date
    /// When checks start again by themselves. Nil means not until someone resumes it.
    public var until: Date?

    public init(since: Date, until: Date? = nil) {
        self.since = since
        self.until = until
    }
}

/// The most serious thing the latest audit turned up, kept so the row can say so until the next audit.
public struct AuditFlag: Codable, Equatable, Sendable {
    public var level: Level
    public var note: String

    public init(level: Level, note: String) {
        self.level = level
        self.note = note
    }
}

/// Everything remembered about a site between checks. Events come from how this changes.
public struct SiteState: Codable, Equatable, Sendable {
    public var lastPulse: Date?
    public var lastMilliseconds: Int?
    public var lastError: String?
    /// Failed pulses in a row.
    public var failures = 0
    /// When the first of those failures happened.
    public var failingSince: Date?
    public var isDown = false
    public var slow = false
    public var slowStreak = 0
    public var certificateExpiry: Date?
    public var certificateStage = CertificateStage.fine

    public var lastAuditAttempt: Date?
    public var audited: Date?
    public var score: Int?
    public var pagesChecked: Int?
    /// Failed checks marked "fix before launch" in the latest audit.
    public var blockers = 0
    public var robotsBlocked = false
    public var homeNoindex = false
    public var auditFlag: AuditFlag?

    // Everything below arrived after 0.2.0. Each is optional, so a file written before it existed still reads.

    /// The pause under way, if any.
    public var pause: Pause?
    /// Pauses that have ended, each with the moment it ended, kept for as long as the samples are.
    public var pauses: [Pause]?
    /// Checks in a row that answered without the phrase.
    public var phraseMisses: Int?
    /// The phrase that has been reported missing. Nil while the page shows it, or nothing is asked.
    public var missingPhrase: String?
    /// When the registry was last asked about the domain, whether or not it answered.
    public var domainChecked: Date?
    public var domainExpiry: Date?
    public var domainStage: DomainStage?

    public init() {}
}

public struct WatchSettings: Codable, Equatable, Sendable {
    public var pulseMinutes = 5
    public var auditHours = 6
    public var notifications = true
    /// One summary of the week, on Monday morning.
    public var weeklySummary = true
    /// Ask the registry once a day when the domain runs out.
    public var domainExpiry = true
    /// Where every event is also posted. Nil until the person enters an address; nothing is ever sent without one.
    public var webhook: String?

    public static let pulseChoices = [1, 5, 15]
    public static let auditChoices = [1, 6, 24]

    public init() {}

    /// A file written before a setting existed still reads, with that setting at its default.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pulseMinutes = try values.decodeIfPresent(Int.self, forKey: .pulseMinutes) ?? 5
        auditHours = try values.decodeIfPresent(Int.self, forKey: .auditHours) ?? 6
        notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        weeklySummary = try values.decodeIfPresent(Bool.self, forKey: .weeklySummary) ?? true
        domainExpiry = try values.decodeIfPresent(Bool.self, forKey: .domainExpiry) ?? true
        webhook = try values.decodeIfPresent(String.self, forKey: .webhook)
    }

    public var pulseInterval: TimeInterval { TimeInterval(pulseMinutes * 60) }
    public var auditInterval: TimeInterval { TimeInterval(auditHours * 3600) }
}

public struct Entry: Codable, Equatable, Sendable {
    public var site: Site
    public var state: SiteState

    public init(site: Site, state: SiteState = SiteState()) {
        self.site = site
        self.state = state
    }
}

/// What is kept in one file: the sites, what is known about each, the event log and the settings.
public struct Library: Codable, Equatable, Sendable {
    public var entries: [Entry] = []
    public var events: [SiteEvent] = []
    public var settings = WatchSettings()
    /// The latest weekly summary, kept so the panel can still show it.
    public var summary: WeekSummary?
    /// The Monday morning most recently dealt with, whether or not anything was sent for it.
    public var weekHandled: Date?

    public init() {}

    /// A file written by an earlier version has no summary; it must still read, or every site would be lost.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        events = try values.decodeIfPresent([SiteEvent].self, forKey: .events) ?? []
        settings = try values.decodeIfPresent(WatchSettings.self, forKey: .settings) ?? WatchSettings()
        summary = try values.decodeIfPresent(WeekSummary.self, forKey: .summary)
        weekHandled = try values.decodeIfPresent(Date.self, forKey: .weekHandled)
    }
}
