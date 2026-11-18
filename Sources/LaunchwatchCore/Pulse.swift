import Foundation
import LaunchcheckCore
import Security

/// One cheap request to a site's home page.
public protocol Pulser: Sendable {
    /// `readingBody` asks for the page itself as well, for a site with a phrase to look for.
    func pulse(_ url: URL, readingBody: Bool) async -> PulseResult
}

extension Pulser {
    public func pulse(_ url: URL) async -> PulseResult {
        await pulse(url, readingBody: false)
    }
}

/// A full audit of a site.
public protocol SiteAuditing: Sendable {
    func audit(_ address: String) async throws -> Report
}

/// The Launchcheck engine, held to a small crawl so it can run every few hours without anyone noticing.
public struct EngineAuditor: SiteAuditing {
    public var maxPages: Int

    public init(maxPages: Int = 25) {
        self.maxPages = maxPages
    }

    public func audit(_ address: String) async throws -> Report {
        var options = Options()
        options.maxPages = maxPages
        options.checkExternalLinks = false
        options.checkImages = false
        options.concurrency = 4
        return try await Auditor(options: options).run(address)
    }
}

/// The real network. Each pulse opens a fresh connection, so the time includes the handshake a new visitor would pay for
/// and the certificate is always presented.
public final class URLSessionPulser: Pulser, @unchecked Sendable {
    private let timeout: TimeInterval
    /// As much of a page as is read when looking for a phrase.
    static let bodyLimit = 2_000_000

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func pulse(_ url: URL, readingBody: Bool) async -> PulseResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = [
            "User-Agent": Watcher.userAgent,
            "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
        ]
        let probe = CertificateProbe(host: url.host)
        let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let started = Date()
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            let waited = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return PulseResult(status: 0, error: "it did not answer like a website", certificateExpiry: probe.expiry, failure: .other)
            }
            let answered = (200..<400).contains(http.statusCode)
            // The time is to the first byte either way. The whole page is read only when there is a phrase to look for,
            // and the start of it when the answer is an error, so whoever wrote the error page can be recognised.
            // If it cannot be read, the pulse still counts and the phrase is simply not judged this time.
            var text: String?
            var complete = false
            if (readingBody && answered) || !answered {
                let limit = answered ? Self.bodyLimit : Self.sampleLimit
                var data = Data()
                do {
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count >= limit { break }
                    }
                    complete = data.count < limit
                    text = String(decoding: data, as: UTF8.self)
                } catch {
                    text = answered ? nil : String(decoding: data, as: UTF8.self)
                }
            }
            bytes.task.cancel()        // the answer has started; nothing more of the page is needed
            // The request's timings are handed over only once the stream has ended, so it is run to its (cancelled) end.
            do { for try await _ in bytes {} } catch {}
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            var phases = await probe.phases(within: 0.4)
            if !complete { phases?.download = nil }
            return PulseResult(status: http.statusCode, milliseconds: waited, certificateExpiry: probe.expiry, body: answered ? text : nil,
                               headers: headers, sample: answered ? nil : text.map { String($0.prefix(Self.sampleLimit)) },
                               finalURL: http.url?.absoluteString, phases: phases)
        } catch {
            let code = (error as? URLError)?.code
            let offline = code == .notConnectedToInternet || code == .dataNotAllowed || code == .internationalRoamingOff
            var failure = Self.failure(code)
            if case .certificate = failure { failure = .certificate(probe.problem(now: Date(), code: code)) }
            return PulseResult(status: 0, error: Self.describe(code), certificateExpiry: probe.expiry, offline: offline, failure: failure,
                               finalURL: (error as? URLError)?.failingURL?.absoluteString)
        }
    }

    /// As much of an error page as is kept to recognise who wrote it.
    static let sampleLimit = 16_000

    /// The kind of failure, for the diagnosis.
    static func failure(_ code: URLError.Code?) -> PulseFailure {
        switch code {
        case .cannotFindHost, .dnsLookupFailed: return .nameNotFound
        case .timedOut: return .timedOut
        case .cannotConnectToHost: return .refused
        case .networkConnectionLost: return .dropped
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return .certificate(nil)
        case .httpTooManyRedirects: return .redirectLoop
        default: return .other
        }
    }

    /// Why it failed, worded to follow "it is down: ".
    static func describe(_ code: URLError.Code?) -> String {
        switch code {
        case .cannotFindHost, .dnsLookupFailed: return "the address does not exist"
        case .timedOut: return "it took too long to answer"
        case .cannotConnectToHost: return "the server refused the connection"
        case .networkConnectionLost: return "the connection was dropped"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
            return "its security certificate is not valid"
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return "this Mac is offline"
        case .httpTooManyRedirects: return "it redirects in a loop"
        default: return "it did not answer"
        }
    }
}

/// Reads the expiry date off the certificate the server presents, then lets the system judge it as usual.
/// It also keeps what a diagnosis may want afterwards: the trust itself, and how the request's time was spent.
final class CertificateProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String?
    private let lock = NSLock()
    private var found: Date?
    private var notBefore: Date?
    private var trust: SecTrust?
    private var timings: PhaseTimings?

    init(host: String?) {
        self.host = host?.lowercased()
    }

    var expiry: Date? {
        lock.lock()
        defer { lock.unlock() }
        return found
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
           let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
           let date = Self.date(kSecOIDX509V1ValidityNotAfter, of: leaf) {
            lock.lock()
            // The site's own certificate wins over one met later on a redirect to another host.
            if found == nil || space.host.lowercased() == host {
                found = date
                notBefore = Self.date(kSecOIDX509V1ValidityNotBefore, of: leaf)
                self.trust = trust
            }
            lock.unlock()
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let read = Self.phases(of: metrics)
        lock.lock()
        timings = read
        lock.unlock()
    }

    /// The request's time by phase. The figures arrive a moment after the request ends, so this waits for them, briefly.
    func phases(within seconds: TimeInterval) async -> PhaseTimings? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let ready = lock.withLock { timings }
            if ready != nil || Date() >= deadline { return ready }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Adds up each phase over every hop of the request, redirects included.
    static func phases(of metrics: URLSessionTaskMetrics) -> PhaseTimings? {
        func ms(_ from: Date?, _ to: Date?) -> Int? {
            guard let from, let to, to >= from else { return nil }
            return Int((to.timeIntervalSince(from) * 1000).rounded())
        }
        func add(_ sum: inout Int?, _ more: Int?) {
            if let more { sum = (sum ?? 0) + more }
        }
        var all = PhaseTimings()
        for hop in metrics.transactionMetrics where hop.resourceFetchType == .networkLoad {
            add(&all.lookup, ms(hop.domainLookupStartDate, hop.domainLookupEndDate))
            // Connecting includes the handshake in what the system reports; here they are told apart.
            let secure = ms(hop.secureConnectionStartDate, hop.secureConnectionEndDate)
            add(&all.secure, secure)
            add(&all.connect, ms(hop.connectStartDate, hop.connectEndDate).map { max(0, $0 - (secure ?? 0)) })
            add(&all.wait, ms(hop.requestStartDate, hop.responseStartDate))
            add(&all.download, ms(hop.responseStartDate, hop.responseEndDate))
        }
        return all == PhaseTimings() ? nil : all
    }

    /// Why the certificate was turned down, worked out only after a request has failed over it.
    func problem(now: Date, code: URLError.Code?) -> CertificateProblem? {
        let (expiry, start, trust) = lock.withLock { (found, notBefore, self.trust) }
        if let expiry, expiry <= now { return .expired(expiry) }
        if let start, start > now { return .notYetValid(start) }
        if code == .serverCertificateHasBadDate { return .expired(expiry) }
        if code == .serverCertificateNotYetValid { return .notYetValid(start) }
        guard let trust else { return nil }
        // Judged once for this name and once for any name: passing only the second means it belongs to someone else.
        if Self.passes(trust, host: host) { return nil }
        if Self.passes(trust, host: nil) { return .wrongHost }
        return code == .serverCertificateHasUnknownRoot || code == .serverCertificateUntrusted ? .untrusted : nil
    }

    private static func passes(_ trust: SecTrust, host: String?) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host.map { $0 as CFString }))
        return SecTrustEvaluateWithError(trust, nil)
    }

    static func date(_ field: CFString, of certificate: SecCertificate) -> Date? {
        let wanted = [field] as CFArray
        guard let values = SecCertificateCopyValues(certificate, wanted, nil) as? [CFString: Any],
              let entry = values[field] as? [CFString: Any],
              let seconds = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }
}

/// Asks whether one more address on a server answers. Used only once a site is confirmed down.
public protocol SideDoorAsking: Sendable {
    /// The status the address answered with, or nil when it did not answer in time.
    func status(of url: URL) async -> Int?
}

public struct URLSessionSideDoor: SideDoorAsking {
    private let timeout: TimeInterval

    /// Short, because the alert waits for it.
    public init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    public func status(of url: URL) async -> Int? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = ["User-Agent": Watcher.userAgent]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (bytes, response) = try? await session.bytes(for: URLRequest(url: url)) else { return nil }
        bytes.task.cancel()
        return (response as? HTTPURLResponse)?.statusCode
    }
}
