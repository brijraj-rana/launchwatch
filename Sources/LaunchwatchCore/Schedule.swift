import Foundation

/// Decides what is due. Pure: the clock is whatever `now` the caller passes in.
public enum Scheduler {
    /// A failed pulse is tried again this soon, so a real outage is confirmed in half a minute and a blip is forgotten.
    public static let retryDelay: TimeInterval = 30
    /// Timers fire a little early or late; a check this close to due counts as due.
    static let slack: TimeInterval = 2

    /// Something has gone wrong once and has not been said yet: a failed pulse, or a page without its phrase.
    /// The next check comes soon, to confirm it or forget it.
    static func confirming(_ state: SiteState) -> Bool {
        if state.failures > 0, !state.isDown { return true }
        return (state.phraseMisses ?? 0) > 0 && state.missingPhrase == nil
    }

    /// A paused site is never due.
    public static func pulseDue(_ state: SiteState, settings: WatchSettings, now: Date) -> Bool {
        if Pausing.isPaused(state, now: now) { return false }
        guard let last = state.lastPulse else { return true }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < 0 { return true }                       // the clock was set back
        if confirming(state) { return elapsed >= retryDelay - slack }
        return elapsed >= settings.pulseInterval - slack
    }

    /// An audit waits for a first pulse, and is not worth running against a site that is paused or not answering.
    public static func auditDue(_ state: SiteState, settings: WatchSettings, now: Date) -> Bool {
        if Pausing.isPaused(state, now: now) { return false }
        guard state.lastPulse != nil, state.failures == 0, !state.isDown else { return false }
        guard let last = state.lastAuditAttempt else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= settings.auditInterval - slack
    }

    public static func pulsesDue(_ entries: [Entry], settings: WatchSettings, now: Date) -> [UUID] {
        entries.filter { pulseDue($0.state, settings: settings, now: now) }.map(\.site.id)
    }

    public static func auditsDue(_ entries: [Entry], settings: WatchSettings, now: Date) -> [UUID] {
        entries.filter { auditDue($0.state, settings: settings, now: now) }.map(\.site.id)
    }

    /// The registry is asked once a day, for a site that has answered, has a domain of its own and is not paused.
    public static let domainInterval: TimeInterval = 86_400

    public static func domainDue(_ entry: Entry, settings: WatchSettings, now: Date) -> Bool {
        guard settings.domainExpiry, entry.state.lastPulse != nil, !Pausing.isPaused(entry.state, now: now),
              Domain.registrable(entry.site.host) != nil else { return false }
        guard let last = entry.state.domainChecked else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= domainInterval - slack
    }

    public static func domainsDue(_ entries: [Entry], settings: WatchSettings, now: Date) -> [UUID] {
        entries.filter { domainDue($0, settings: settings, now: now) }.map(\.site.id)
    }

    /// When the next pulse falls due, or nil with no sites to check. After a sleep this is in the past, which means "now".
    /// A site paused for a while is due when its pause ends; one paused until resumed is never due.
    public static func nextPulse(_ entries: [Entry], settings: WatchSettings, now: Date) -> Date? {
        entries.compactMap { entry -> Date? in
            if Pausing.isPaused(entry.state, now: now) { return entry.state.pause?.until }
            guard let last = entry.state.lastPulse else { return now }
            return last.addingTimeInterval(confirming(entry.state) ? retryDelay : settings.pulseInterval)
        }.min()
    }
}
