import Foundation

/// A site being watched.
public struct Site: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The home page, as in "https://example.com/".
    public var url: String
    public var host: String
    public var added: Date

    public init(id: UUID = UUID(), url: String, host: String, added: Date) {
        self.id = id
        self.url = url
        self.host = host
        self.added = added
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

    public init(status: Int, milliseconds: Int = 0, error: String? = nil, certificateExpiry: Date? = nil, offline: Bool = false) {
        self.status = status
        self.milliseconds = milliseconds
        self.error = error
        self.certificateExpiry = certificateExpiry
        self.offline = offline
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

    public init(date: Date, status: Int, milliseconds: Int) {
        self.date = date
        self.status = status
        self.milliseconds = milliseconds
    }

    public var ok: Bool { (200..<400).contains(status) }

    enum CodingKeys: String, CodingKey {
        case date = "t", status = "s", milliseconds = "m"
    }
}

public enum Level: Int, Codable, Comparable, Sendable {
    case critical, warning, good

    public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
}

public enum EventKind: String, Codable, Sendable {
    case down, recovered, slow
    case certificateSoon, certificateUrgent, certificateExpired
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

    public init(id: UUID = UUID(), site: Site, kind: EventKind, level: Level, message: String, brief: String, date: Date) {
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

    public init() {}
}

public struct WatchSettings: Codable, Equatable, Sendable {
    public var pulseMinutes = 5
    public var auditHours = 6
    public var notifications = true
    /// One summary of the week, on Monday morning.
    public var weeklySummary = true

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
