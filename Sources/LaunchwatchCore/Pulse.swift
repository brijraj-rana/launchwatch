import Foundation
import LaunchcheckCore
import Security

/// One cheap request to a site's home page.
public protocol Pulser: Sendable {
    func pulse(_ url: URL) async -> PulseResult
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

    public init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    public func pulse(_ url: URL) async -> PulseResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (compatible; Launchwatch/0.1)",
            "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
        ]
        let probe = CertificateProbe(host: url.host)
        let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let started = Date()
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            let waited = Int(Date().timeIntervalSince(started) * 1000)
            bytes.task.cancel()        // the answer has started; the rest of the page is not needed
            guard let http = response as? HTTPURLResponse else {
                return PulseResult(status: 0, error: "it did not answer like a website", certificateExpiry: probe.expiry)
            }
            return PulseResult(status: http.statusCode, milliseconds: waited, certificateExpiry: probe.expiry)
        } catch {
            let code = (error as? URLError)?.code
            let offline = code == .notConnectedToInternet || code == .dataNotAllowed || code == .internationalRoamingOff
            return PulseResult(status: 0, error: Self.describe(code), certificateExpiry: probe.expiry, offline: offline)
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
final class CertificateProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let host: String?
    private let lock = NSLock()
    private var found: Date?

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
           let date = Self.notValidAfter(leaf) {
            lock.lock()
            // The site's own certificate wins over one met later on a redirect to another host.
            if found == nil || space.host.lowercased() == host { found = date }
            lock.unlock()
        }
        completionHandler(.performDefaultHandling, nil)
    }

    static func notValidAfter(_ certificate: SecCertificate) -> Date? {
        let wanted = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, wanted, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let seconds = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }
}
