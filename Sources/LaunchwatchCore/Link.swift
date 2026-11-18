import Foundation

/// Answers whether any app on this Mac opens a kind of link. Behind a protocol so tests and README images
/// do not depend on what happens to be installed.
public protocol SchemeChecking: Sendable {
    func hasApp(for url: URL) -> Bool
}

/// The way from a site here to its full report in Launchcheck.
public enum ReportLink {
    public static let scheme = "launchcheck"

    /// "launchcheck://open?site=example.com"
    public static func url(for site: Site) -> URL? {
        guard let home = URL(string: site.url), let host = home.host, !host.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "site", value: host.lowercased() + (home.port.map { ":\($0)" } ?? ""))]
        return parts.url
    }

    /// True when some app is registered for the scheme, so a button that opens the report would do something.
    public static func available(_ schemes: SchemeChecking) -> Bool {
        guard let probe = URL(string: "\(scheme)://open") else { return false }
        return schemes.hasApp(for: probe)
    }
}
