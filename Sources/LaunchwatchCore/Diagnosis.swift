import Foundation

// MARK: What a pulse can tell

/// Why a certificate was turned down.
public enum CertificateProblem: Equatable, Sendable {
    case expired(Date?)
    case notYetValid(Date?)
    /// Valid, but issued for another name.
    case wrongHost
    /// Not signed by anyone the system trusts.
    case untrusted
}

/// The kind of failure when a site gave no answer at all.
public enum PulseFailure: Equatable, Sendable {
    case nameNotFound
    case timedOut
    case refused
    case dropped
    case certificate(CertificateProblem?)
    case redirectLoop
    case other
}

/// One request's time, split into the stretches it went through, in milliseconds. A stretch that did not happen is nil.
/// Short keys, because one of these is kept with every sample.
public struct PhaseTimings: Codable, Equatable, Sendable {
    public var lookup: Int?
    public var connect: Int?
    public var secure: Int?
    public var wait: Int?
    /// Only measured when the whole page was read, which happens for a site with a phrase to look for.
    public var download: Int?

    public init(lookup: Int? = nil, connect: Int? = nil, secure: Int? = nil, wait: Int? = nil, download: Int? = nil) {
        self.lookup = lookup
        self.connect = connect
        self.secure = secure
        self.wait = wait
        self.download = download
    }

    enum CodingKeys: String, CodingKey {
        case lookup = "d", connect = "c", secure = "s", wait = "w", download = "l"
    }

    public enum Phase: CaseIterable, Sendable {
        case lookup, connect, secure, wait, download

        /// As the subject of "... took 1.6 s".
        public var words: String {
            switch self {
            case .lookup: return "looking up the name"
            case .connect: return "connecting"
            case .secure: return "the secure handshake"
            case .wait: return "waiting for the server"
            case .download: return "downloading the page"
            }
        }
    }

    public subscript(phase: Phase) -> Int? {
        switch phase {
        case .lookup: return lookup
        case .connect: return connect
        case .secure: return secure
        case .wait: return wait
        case .download: return download
        }
    }
}

/// The likely cause of an event: which branch of the diagnosis explained it, and the sentence to show.
public struct Cause: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case domainLapsed, nameNotFound
        case certificateExpired, certificateNotYetValid, certificateWrongHost, certificateUntrusted
        case refused, timedOut, dropped
        case cloudflareOrigin, cloudflareItself, platform
        case status
        case redirectLoop, redirectElsewhere
        case homePageOnly
        case phaseGrew, phaseMost
        case pageChanged
    }

    public var kind: Kind
    public var sentence: String

    public init(_ kind: Kind, _ sentence: String) {
        self.kind = kind
        self.sentence = sentence
    }
}

/// Whether anything else on the server answers, asked only once a site is confirmed down.
public enum SideDoor: Equatable, Sendable {
    case notAsked
    /// This path answered properly, as in "/robots.txt".
    case answered(String)
    case silent
}

/// Everything known at the moment a site is confirmed down.
public struct DownEvidence: Equatable, Sendable {
    public var host: String
    public var failure: PulseFailure?
    public var status: Int
    public var headers: [String: String]
    public var sample: String
    public var finalURL: String?
    /// When the registry said the domain runs out, if it has been asked.
    public var domainExpiry: Date?
    public var sideDoor: SideDoor
    public var now: Date

    public init(host: String, failure: PulseFailure? = nil, status: Int = 0, headers: [String: String] = [:], sample: String = "",
                finalURL: String? = nil, domainExpiry: Date? = nil, sideDoor: SideDoor = .notAsked, now: Date) {
        self.host = host
        self.failure = failure
        self.status = status
        self.headers = headers
        self.sample = sample
        self.finalURL = finalURL
        self.domainExpiry = domainExpiry
        self.sideDoor = sideDoor
        self.now = now
    }

    public init(site: Site, state: SiteState, result: PulseResult, sideDoor: SideDoor = .notAsked, now: Date) {
        self.init(host: site.host, failure: result.failure, status: result.status, headers: result.headers, sample: result.sample ?? result.body ?? "",
                  finalURL: result.finalURL, domainExpiry: state.domainExpiry, sideDoor: sideDoor, now: now)
    }
}

// MARK: Diagnosis

/// Works out the likely cause of an event from what one request brought back. Pure: evidence in, a cause or nothing out.
/// A cause adds to the event's own words and never repeats them, a guess is called likely, and with nothing to go on it says nothing.
public enum Diagnosis {
    /// A platform whose error pages can be told apart from a site's own.
    public enum Platform: String, CaseIterable, Sendable {
        case cloudflare = "Cloudflare", vercel = "Vercel", netlify = "Netlify", webflow = "Webflow", githubPages = "GitHub Pages"
    }

    // MARK: Down

    /// The causes of an outage, tried in order; the first that explains it wins.
    public static func down(_ evidence: DownEvidence) -> Cause? {
        if let cause = name(evidence) { return cause }
        if let cause = certificate(evidence) { return cause }
        if let cause = connection(evidence) { return cause }
        if let cause = answer(evidence) { return cause }
        return nil
    }

    /// True when asking for another path could tell a broken home page from a broken server:
    /// the server answered with an error of its own, or accepted the connection and then said nothing.
    public static func wantsSideDoor(_ evidence: DownEvidence) -> Bool {
        if evidence.failure == .timedOut { return true }
        guard evidence.failure == nil, evidence.status >= 400 else { return false }
        // A platform that has explained the error has already answered the question.
        return platformCause(evidence) == nil
    }

    private static func name(_ evidence: DownEvidence) -> Cause? {
        guard evidence.failure == .nameNotFound else { return nil }
        if let expiry = evidence.domainExpiry, expiry <= evidence.now {
            return Cause(.domainLapsed, "The domain registration ran out on \(day(expiry)), which is likely why the name no longer resolves.")
        }
        return Cause(.nameNotFound, "The name does not resolve, so the trouble is with DNS or the domain and not with the server.")
    }

    private static func certificate(_ evidence: DownEvidence) -> Cause? {
        guard case .certificate(let problem) = evidence.failure, let problem else { return nil }
        switch problem {
        case .expired(let date):
            return Cause(.certificateExpired, date.map { "The certificate ran out on \(day($0))." } ?? "The certificate has run out.")
        case .notYetValid(let date):
            return Cause(.certificateNotYetValid, date.map { "The certificate is not valid until \(day($0))." } ?? "The certificate is not valid yet.")
        case .wrongHost:
            return Cause(.certificateWrongHost, "The certificate is for a different name, not \(evidence.host).")
        case .untrusted:
            return Cause(.certificateUntrusted, "The certificate is not signed by an authority that browsers trust.")
        }
    }

    private static func connection(_ evidence: DownEvidence) -> Cause? {
        switch evidence.failure {
        case .refused:
            return Cause(.refused, "The machine is reachable but nothing on it is accepting visitors, so the web server has likely stopped.")
        case .timedOut:
            if case .answered(let path) = evidence.sideDoor {
                return Cause(.homePageOnly, "The server is up, the home page is failing: \(named(path)) answers and the home page never does.")
            }
            return Cause(.timedOut, "Nothing came back before the time ran out, so the server is likely overloaded or cut off.")
        case .dropped:
            return Cause(.dropped, "The connection opened and was cut before any answer came.")
        case .redirectLoop:
            let last = evidence.finalURL.map { "The loop was last seen at \($0)." }
            return Cause(.redirectLoop, last ?? "Each address sends the visitor on to another and none of them answers.")
        default:
            return nil
        }
    }

    /// The server answered, with an error.
    private static func answer(_ evidence: DownEvidence) -> Cause? {
        guard evidence.failure == nil, evidence.status >= 400 else { return nil }
        if let cause = platformCause(evidence) { return cause }

        // Somewhere else entirely: the error belongs to wherever the visitor is sent.
        if let final = evidence.finalURL.flatMap({ URL(string: $0)?.host?.lowercased() }), !sameSite(final, evidence.host) {
            return Cause(.redirectElsewhere, "It now redirects to \(final), which answers with error \(evidence.status).")
        }

        // Knowing the rest of the server answers says more than what the code usually means, so it is said instead.
        if case .answered(let path) = evidence.sideDoor {
            return Cause(.homePageOnly, "The server is up, the home page is failing: \(named(path)) still answers.")
        }
        return Diagnosis.meaning(of: evidence.status).map { Cause(.status, "Error \(evidence.status) usually means \($0).") }
    }

    /// What an error status usually means, to finish "usually means ...". Nil for a code with no usual meaning worth saying.
    public static func meaning(of status: Int) -> String? {
        switch status {
        case 500: return "the site's own code failed"
        case 502, 504: return "the host cannot reach the app behind it"
        case 503: return "the server is overloaded or in maintenance"
        case 401: return "the site now asks for a password"
        case 403: return "the server is blocking visitors"
        case 404, 410: return "the home page is gone"
        case 429: return "the server is turning away requests that come too often"
        case 508: return "the hosting account has run out of resources"
        default: return nil
        }
    }

    // MARK: Platforms

    /// Whose error page it is, judged by headers first and then by small marks in the page.
    public static func platform(headers: [String: String], sample: String) -> Platform? {
        let server = headers["server"]?.lowercased() ?? ""
        let page = sample.lowercased()
        // Webflow and Netlify sites often sit behind other networks, so the more specific marks are read first.
        if headers["x-vercel-error"] != nil || headers["x-vercel-id"] != nil || server == "vercel" { return .vercel }
        if headers["x-nf-request-id"] != nil || server.hasPrefix("netlify") { return .netlify }
        if headers["x-github-request-id"] != nil || server == "github.com" { return .githubPages }
        if headers.keys.contains(where: { $0.hasPrefix("x-wf-") }) || page.contains("data-wf-site") || page.contains("webflow.com") { return .webflow }
        if headers["cf-ray"] != nil || server == "cloudflare" { return .cloudflare }
        return nil
    }

    /// What Cloudflare's own codes say about the server behind it.
    static func cloudflare(_ status: Int) -> String? {
        switch status {
        case 520: return "the server behind it gave an answer it could not read"
        case 521: return "the server behind it refused the connection"
        case 522: return "the server behind it did not answer in time"
        case 523: return "it has no route to the server behind it"
        case 524: return "the server behind it accepted the request and never answered"
        case 525: return "the secure handshake with the server behind it failed"
        case 526: return "the certificate on the server behind it is not valid"
        case 530: return "it could not find the server behind the name"
        default: return nil
        }
    }

    /// What Vercel's error names mean, for the ones that explain themselves.
    static func vercel(_ code: String) -> String? {
        switch code.uppercased() {
        case "DEPLOYMENT_NOT_FOUND": return "the deployment is gone or the domain no longer points at one"
        case "DEPLOYMENT_PAUSED": return "the project has been paused"
        case "DEPLOYMENT_DISABLED": return "the deployment has been disabled"
        case "DEPLOYMENT_DELETED": return "the deployment has been deleted"
        case "FUNCTION_INVOCATION_FAILED", "EDGE_FUNCTION_INVOCATION_FAILED", "MIDDLEWARE_INVOCATION_FAILED": return "the site's own code failed"
        case "FUNCTION_INVOCATION_TIMEOUT", "EDGE_FUNCTION_INVOCATION_TIMEOUT", "MIDDLEWARE_INVOCATION_TIMEOUT": return "the site's own code took too long"
        case "FUNCTION_THROTTLED": return "the site's code is being held back by a usage limit"
        case "DNS_HOSTNAME_NOT_FOUND", "DNS_HOSTNAME_RESOLVE_FAILED": return "it could not find the server the site passes requests to"
        default: return nil
        }
    }

    private static func platformCause(_ evidence: DownEvidence) -> Cause? {
        guard evidence.failure == nil, evidence.status >= 400,
              let platform = platform(headers: evidence.headers, sample: evidence.sample) else { return nil }
        let status = evidence.status
        let page = evidence.sample.lowercased()
        switch platform {
        case .cloudflare:
            if let said = cloudflare(status) {
                return Cause(.cloudflareOrigin, "Cloudflare is up but \(said) (error \(status)), so the trouble is at the host and not at Cloudflare.")
            }
            // Cloudflare's own failures come on Cloudflare's own page; anything else is the site's error passed through.
            if status >= 500, page.contains("cf-error-details") || page.contains("cloudflare-nginx") || page.contains("cf-wrapper") {
                return Cause(.cloudflareItself, "Likely Cloudflare itself: the error page is Cloudflare's own, not the site's.")
            }
            return nil
        case .vercel:
            if let code = evidence.headers["x-vercel-error"], let said = vercel(code) {
                return Cause(.platform, "Vercel says \(code): \(said).")
            }
            return likely(platform, status)
        case .netlify, .webflow, .githubPages:
            return likely(platform, status)
        }
    }

    /// "Likely the host: 502 from Vercel, which usually means the host cannot reach the app behind it."
    private static func likely(_ platform: Platform, _ status: Int) -> Cause {
        if status == 404 {
            return Cause(.platform, "\(platform.rawValue) has no site for this address: the project was removed, unpublished or the domain was disconnected.")
        }
        let means = meaning(of: status).map { ", which usually means \($0)" } ?? ""
        return Cause(.platform, "Likely the host: \(status) from \(platform.rawValue)\(means).")
    }

    // MARK: Slow

    /// Fewest earlier readings before "usually" can be said about a phase.
    public static let phaseHistoryNeeded = 12

    /// Which stretch of the request the time went on. With enough history it names the one that grew, against its usual;
    /// without, only the one that took most of the time. Nil when the readings do not single one out.
    public static func slow(_ now: PhaseTimings?, history: [PhaseTimings]) -> Cause? {
        guard let now else { return nil }
        let measured = PhaseTimings.Phase.allCases.compactMap { phase in now[phase].map { (phase: phase, ms: $0) } }
        let total = measured.reduce(0) { $0 + $1.ms }
        guard total > 0 else { return nil }

        var grown: [(phase: PhaseTimings.Phase, ms: Int, usual: Int)] = []
        for reading in measured {
            let before = history.compactMap { $0[reading.phase] }
            guard before.count >= phaseHistoryNeeded, let usual = Stats.median(before) else { continue }
            grown.append((reading.phase, reading.ms, usual))
        }
        if let worst = grown.max(by: { ($0.ms - $0.usual) < ($1.ms - $1.usual) }) {
            let growth = worst.ms - worst.usual
            let allGrowth = grown.reduce(0) { $0 + max(0, $1.ms - $1.usual) }
            // It has to be most of the slowdown, and a real one, to be named.
            guard growth >= 100, growth * 2 >= allGrowth, worst.ms >= worst.usual * 2 else { return nil }
            return Cause(.phaseGrew, "\(capitalized(worst.phase.words)) took \(Words.time(worst.ms)), usually \(Words.time(worst.usual)).")
        }
        guard let most = measured.max(by: { $0.ms < $1.ms }), most.ms * 2 >= total else { return nil }
        return Cause(.phaseMost, "Most of the time went on \(most.phase.words) (\(Words.time(most.ms))).")
    }

    // MARK: Must contain

    /// What the page is now, when it stopped showing its phrase: sent somewhere else, or a different page under the same address.
    public static func missingPhrase(host: String, finalURL: String?, body: String?) -> Cause? {
        if let final = finalURL.flatMap({ URL(string: $0)?.host?.lowercased() }), !sameSite(final, host) {
            return Cause(.redirectElsewhere, "The home page now redirects to \(final).")
        }
        guard let title = title(of: body ?? ""), !title.isEmpty else { return nil }
        return Cause(.pageChanged, "The page's title is now “\(title)”.")
    }

    /// The words between `<title>` and `</title>`, on one line and not too long.
    static func title(of html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let start = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title", options: .caseInsensitive, range: start.upperBound..<html.endIndex) else { return nil }
        let raw = Phrase.text(of: String(html[start.upperBound..<close.lowerBound]), tagsBecome: "")
        let words = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > 70 ? String(words.prefix(69)) + "…" : words
    }

    // MARK: Helpers

    /// Two hosts on the same registered name are the same site: "www.acme.com" and "acme.com", "shop.acme.co.uk" and "acme.co.uk".
    static func sameSite(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        if a == b { return true }
        if let x = Domain.registrable(a), let y = Domain.registrable(b) { return x == y }
        return false
    }

    /// "/robots.txt" as it is said in a sentence.
    private static func named(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "3 Nov 2026", the same on every Mac, in UTC as the registry and the certificate state it.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
