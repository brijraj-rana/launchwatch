import Foundation

/// Which name a site's owner pays for each year, and when the registry says it runs out.
public enum Domain {
    /// Second-level labels that countries hand out names under: the "co" in co.uk, the "com" in com.au.
    /// Under a two-letter country ending, a name with one of these in second place is three labels long.
    static let secondLevel: Set<String> = [
        "co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "mil", "govt", "gob", "ltd", "plc", "sch",
    ]

    /// Endings the rule above would miss, because their second label is also an ordinary word or name.
    static let otherEndings: Set<String> = [
        "me.uk", "nhs.uk", "police.uk", "id.au", "asn.au", "gen.in", "firm.in", "ind.in", "res.in", "nic.in", "gen.nz", "geek.nz",
        "kiwi.nz", "maori.nz", "school.nz", "school.za", "web.za", "nom.za", "nom.br", "art.br", "blog.br", "eco.br", "esp.br",
        "info.pl", "biz.pl", "waw.pl", "nom.es", "info.tr", "web.tr", "biz.tr", "idv.tw", "idv.hk", "per.sg", "info.vn", "name.vn",
        "biz.vn", "web.id", "my.id", "biz.id", "in.th", "in.ua", "kiev.ua", "msk.ru", "spb.ru", "priv.no", "tm.fr", "asso.fr",
        "nom.fr", "tm.mc", "info.ke", "me.ke", "name.ng",
    ]

    /// Hosts lent out by a platform. The name above them belongs to the platform, so its expiry is not this site's business.
    static let borrowed: Set<String> = [
        "github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com",
        "herokuapp.com", "onrender.com", "fly.dev", "myshopify.com", "webflow.io", "framer.website", "framer.app",
        "wixsite.com", "squarespace.com", "wordpress.com", "blogspot.com", "surge.sh", "azurewebsites.net", "cloudfront.net",
        "amazonaws.com", "appspot.com", "glitch.me", "replit.app", "carrd.co", "notion.site", "substack.com", "tumblr.com", "ghost.io",
    ]

    /// "shop.acme.co.uk" gives "acme.co.uk"; "www.example.com" gives "example.com". Nil for an address with no domain
    /// to ask about: an IP address, "localhost", or a host borrowed from a platform. There is no full list of endings here,
    /// only the common ones; a guess that turns out wrong gets no answer from the registry and is quietly dropped.
    public static func registrable(_ host: String) -> String? {
        var name = host.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, !labels.contains(where: \.isEmpty), !name.contains(":") else { return nil }
        // An IPv4 address is all digits; a real ending never is.
        guard let ending = labels.last, ending.contains(where: \.isLetter), ending.count >= 2 else { return nil }

        var kept = 2
        if labels.count >= 3 {
            let second = labels[labels.count - 2]
            if otherEndings.contains(second + "." + ending) || (ending.count == 2 && secondLevel.contains(second)) { kept = 3 }
        }
        let domain = labels.suffix(kept).joined(separator: ".")
        // On a platform's host the registrable name is the platform's, whatever sits in front of it.
        if borrowed.contains(domain) || borrowed.contains(where: { name.hasSuffix("." + $0) }) { return nil }
        return domain
    }
}

/// What a registry answers about a domain, read from RDAP, the JSON that replaced WHOIS.
public enum RDAP {
    public static let service = "https://rdap.org/domain/"

    /// Where to ask about a domain. rdap.org looks up which registry holds the ending and redirects there.
    public static func url(for domain: String) -> URL? {
        guard let name = domain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !name.isEmpty else { return nil }
        return URL(string: service + name)
    }

    /// The day the registration runs out, from the "expiration" event. Nil when the answer is not RDAP or has no such event.
    public static func expiry(from data: Data) -> Date? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = object["events"] as? [[String: Any]] else { return nil }
        func date(of action: String) -> Date? {
            events.first { ($0["eventAction"] as? String)?.lowercased() == action }
                .flatMap { $0["eventDate"] as? String }.flatMap(parse)
        }
        // The registry's date is the one that counts. Some answers carry only the registrar's.
        return date(of: "expiration") ?? date(of: "registrar expiration")
    }

    /// RDAP dates are RFC 3339: with or without fractions of a second, in UTC or with an offset.
    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        // A few registries leave the time zone off, or give the day alone. Read those as UTC.
        let loose = DateFormatter()
        loose.locale = Locale(identifier: "en_US_POSIX")
        loose.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            loose.dateFormat = format
            if let date = loose.date(from: trimmed) { return date }
        }
        return nil
    }
}

public enum DomainAnswer: Equatable, Sendable {
    case expires(Date)
    /// The registry answered, with nothing usable: no such domain, no expiry published, too many questions.
    case unknown
    /// The question never arrived. Worth asking again sooner than tomorrow.
    case unreachable
}

/// Asks when a domain's registration runs out.
public protocol DomainLookup: Sendable {
    func expiry(of domain: String) async -> DomainAnswer
}

/// The real thing: one GET to rdap.org, which redirects to the registry that holds the ending.
public struct RDAPClient: DomainLookup {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func expiry(of domain: String) async -> DomainAnswer {
        guard let url = RDAP.url(for: domain) else { return .unknown }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("application/rdap+json, application/json;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue(Watcher.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request) else { return .unreachable }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let date = RDAP.expiry(from: data) else { return .unknown }
        return .expires(date)
    }
}
