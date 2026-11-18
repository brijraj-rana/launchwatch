import Foundation

/// The three lengths a pause can be asked for.
public enum PauseLength: CaseIterable, Sendable {
    case hour, tomorrow, untilResumed

    /// The hour checks start again after "until tomorrow": morning, not midnight, so nothing is raised while its owner sleeps.
    public static let morning = 9

    public var title: String {
        switch self {
        case .hour: return "1 hour"
        case .tomorrow: return "Until tomorrow"
        case .untilResumed: return "Until resumed"
        }
    }

    /// When the pause ends by itself, or nil when it waits to be resumed.
    public func end(from now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .hour:
            return now.addingTimeInterval(3600)
        case .tomorrow:
            let today = calendar.startOfDay(for: now)
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return now.addingTimeInterval(86_400) }
            return calendar.date(bySettingHour: Self.morning, minute: 0, second: 0, of: tomorrow) ?? tomorrow.addingTimeInterval(Double(Self.morning) * 3600)
        case .untilResumed:
            return nil
        }
    }
}

/// The rules of pausing. Pure: state and the clock go in, a new state comes out.
public enum Pausing {
    /// True while a pause is under way. One whose time has come is over, whether or not anyone has tidied it away.
    public static func isPaused(_ state: SiteState, now: Date) -> Bool {
        guard let pause = state.pause else { return false }
        guard let until = pause.until else { return true }
        return now < until
    }

    /// Starts a pause. Whatever was going wrong is forgotten, so nothing is carried across it:
    /// a site still broken afterwards is reported afresh, and one that mended in the meantime says nothing.
    public static func paused(_ state: SiteState, until: Date?, now: Date) -> SiteState {
        var state = ended(state, at: now)
        state.pause = Pause(since: now, until: until)
        state.failures = 0
        state.failingSince = nil
        state.isDown = false
        state.lastError = nil
        state.slow = false
        state.slowStreak = 0
        state.phraseMisses = nil
        state.missingPhrase = nil
        return state
    }

    /// Ends the pause now, by hand.
    public static func resumed(_ state: SiteState, now: Date) -> SiteState {
        ended(state, at: now)
    }

    /// Tidies away a pause whose time has come, and forgets pauses older than the samples.
    public static func settled(_ state: SiteState, now: Date) -> SiteState {
        var state = state
        if let pause = state.pause, let until = pause.until, now >= until {
            state = ended(state, at: until)
        }
        if let pauses = state.pauses {
            let oldest = now.addingTimeInterval(-Stats.keep)
            let kept = pauses.filter { ($0.until ?? now) >= oldest }
            state.pauses = kept.isEmpty ? nil : kept
        }
        return state
    }

    private static func ended(_ state: SiteState, at moment: Date) -> SiteState {
        var state = state
        guard let pause = state.pause else { return state }
        state.pause = nil
        let end = max(pause.since, min(moment, pause.until ?? moment))
        if end > pause.since { state.pauses = (state.pauses ?? []) + [Pause(since: pause.since, until: end)] }
        return state
    }

    /// Every stretch the site spent paused, oldest first, each with an end. The one under way ends at `now`.
    public static func spans(_ state: SiteState, now: Date) -> [Pause] {
        var all = state.pauses ?? []
        if let pause = state.pause {
            all.append(Pause(since: pause.since, until: min(now, pause.until ?? now)))
        }
        return all.filter { ($0.until ?? now) > $0.since }.sorted { $0.since < $1.since }
    }
}

extension Words {
    /// "Paused until 14:00" today, "Paused until Thu 09:00" on another day, "Paused until resumed" with no end.
    public static func paused(until: Date?, now: Date, calendar: Calendar = .current) -> String {
        guard let until else { return "Paused until resumed" }
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = calendar.locale ?? .current
        if calendar.isDate(until, inSameDayAs: now) { return "Paused until \(until.formatted(time))" }
        var day = Date.FormatStyle().weekday(.abbreviated)
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = calendar.locale ?? .current
        return "Paused until \(until.formatted(day)) \(until.formatted(time))"
    }
}
