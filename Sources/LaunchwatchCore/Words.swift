import Foundation

/// Numbers turned into the words a person would use.
public enum Words {
    /// "a minute", "12 minutes", "3 hours", "2 days".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes <= 1 { return "a minute" }
        if minutes < 90 { return "\(minutes) minutes" }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return "\(hours) hours" }
        return "\(Int((seconds / 86_400).rounded())) days"
    }

    /// "310 ms", "2.4 s".
    public static func time(_ milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1000)
    }

    /// "expires in 9 days", "expires tomorrow", "expires today", "has expired".
    public static func expiry(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "has expired" }
        let days = Int(seconds / 86_400)
        if days == 0 { return "expires today" }
        if days == 1 { return "expires tomorrow" }
        return "expires in \(days) days"
    }

    /// "99.8%". Never rounds up to 100% while there was any downtime.
    public static func percent(_ fraction: Double) -> String {
        if fraction >= 1 { return "100%" }
        let tenths = (fraction * 1000).rounded(.down) / 10
        return tenths == tenths.rounded() ? "\(Int(tenths))%" : String(format: "%.1f%%", tenths)
    }

    /// "/pricing" for an address on the site, "the home page" for its root.
    public static func path(of address: String) -> String {
        guard let url = URL(string: address) else { return address }
        let path = url.path
        return path.isEmpty || path == "/" ? "the home page" : path
    }

    public static func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }
}
