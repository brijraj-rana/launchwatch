import Foundation

/// Decides what is due. Pure: the clock is whatever `now` the caller passes in.
public enum Scheduler {
    /// A failed pulse is tried again this soon, so a real outage is confirmed in half a minute and a blip is forgotten.
    public static let retryDelay: TimeInterval = 30
    /// Timers fire a little early or late; a check this close to due counts as due.
    static let slack: TimeInterval = 2

    public static func pulseDue(_ state: SiteState, settings: WatchSettings, now: Date) -> Bool {
        guard let last = state.lastPulse else { return true }
        let elapsed = now.timeIntervalSince(last)
        if elapsed < 0 { return true }                       // the clock was set back
        if state.failures > 0, !state.isDown { return elapsed >= retryDelay - slack }
        return elapsed >= settings.pulseInterval - slack
    }

    /// An audit waits for a first pulse, and is not worth running against a site that is not answering.
    public static func auditDue(_ state: SiteState, settings: WatchSettings, now: Date) -> Bool {
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

    /// When the next pulse falls due, or nil with no sites. After a sleep this is in the past, which means "now".
    public static func nextPulse(_ entries: [Entry], settings: WatchSettings, now: Date) -> Date? {
        entries.map { entry -> Date in
            guard let last = entry.state.lastPulse else { return now }
            let wait = entry.state.failures > 0 && !entry.state.isDown ? retryDelay : settings.pulseInterval
            return last.addingTimeInterval(wait)
        }.min()
    }
}
