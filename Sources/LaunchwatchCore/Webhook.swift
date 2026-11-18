import Foundation

/// Telling a channel: every event that is said on this Mac can also be posted to one address.
public enum Webhook {
    /// Who is on the other end, judged by the host. It decides the shape of the JSON.
    public enum Flavor: Equatable, Sendable {
        case slack, discord, plain
    }

    /// One thing to say: an event, the weekly summary, or the test.
    public struct Message: Equatable, Sendable {
        public var text: String
        public var host: String?
        public var kind: String
        public var level: String?
        public var date: Date
        /// The likely cause, already part of `text`, and on its own for a script that wants it.
        public var cause: String?

        public init(text: String, host: String? = nil, kind: String, level: String? = nil, date: Date, cause: String? = nil) {
            self.cause = cause
            self.text = text
            self.host = host
            self.kind = kind
            self.level = level
            self.date = date
        }

        public init(_ event: SiteEvent) {
            let level: String
            switch event.level {
            case .critical: level = "critical"
            case .warning: level = "warning"
            case .good: level = "good"
            }
            self.init(text: event.full, host: event.host, kind: event.kind.rawValue, level: level, date: event.date, cause: event.cause)
        }

        public init(_ summary: WeekSummary) {
            self.init(text: summary.text(now: summary.date), kind: "weeklySummary", date: summary.date)
        }

        public static func test(now: Date) -> Message {
            Message(text: "Launchwatch can reach this channel. Events from your sites will be posted here.", kind: "test", date: now)
        }
    }

    /// Discord refuses anything longer.
    static let discordLimit = 2000

    /// The address as typed, if it is one a request can go to. Nil for nothing, for spaces, and for anything that is not http or https.
    public static func url(from text: String?) -> URL? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, !trimmed.contains(" "),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    public static func flavor(of url: URL) -> Flavor {
        let host = url.host?.lowercased() ?? ""
        if host == "hooks.slack.com" || host == "hooks.slack-gov.com" { return .slack }
        let discord = ["discord.com", "discordapp.com", "canary.discord.com", "ptb.discord.com"]
        if discord.contains(host), url.path.hasPrefix("/api/webhooks/") { return .discord }
        return .plain
    }

    /// The JSON to post, as a dictionary: `text` for Slack, `content` for Discord, and for anyone else `text`
    /// with the facts beside it, so a script can read them and a Slack-compatible receiver still shows a line.
    public static func payload(_ message: Message, for flavor: Flavor) -> [String: Any] {
        switch flavor {
        case .slack:
            return ["text": escapedForSlack(message.text)]
        case .discord:
            // No mentions: a page title is the site's words, and "@everyone" in one must not ring a whole server.
            return ["content": String(message.text.prefix(discordLimit)), "allowed_mentions": ["parse": [String]()]]
        case .plain:
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime]
            var body: [String: Any] = ["text": message.text, "kind": message.kind, "date": stamp.string(from: message.date), "source": "Launchwatch"]
            if let host = message.host { body["site"] = host }
            if let level = message.level { body["level"] = level }
            if let cause = message.cause { body["cause"] = cause }
            return body
        }
    }

    /// Slack reads `&`, `<` and `>` as markup, so they are sent as entities.
    static func escapedForSlack(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The whole request, or nil when there is no usable address. With no address there is no request: this is the only place one is made.
    public static func request(to address: String?, _ message: Message, timeout: TimeInterval = 15) -> URLRequest? {
        guard let url = url(from: address) else { return nil }
        let body = payload(message, for: flavor(of: url))
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Watcher.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Why a delivery failed, as a sentence for Settings. Nil when the status means it arrived.
    public static func problem(status: Int) -> String? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return "The webhook refused the message (error \(status)). The address may have been revoked."
        case 404, 410: return "The webhook no longer exists (error \(status))."
        case 429: return "The webhook is busy and turned the message away (error 429)."
        default: return "The webhook answered with error \(status)."
        }
    }

    public static let unreachable = "The webhook could not be reached."
}

/// Sends one message to the webhook. Nil means it arrived; otherwise a sentence saying why not.
public protocol WebhookPosting: Sendable {
    func post(_ request: URLRequest) async -> String?
}

public struct URLSessionWebhook: WebhookPosting {
    public init() {}

    public func post(_ request: URLRequest) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(for: request) else { return Webhook.unreachable }
        guard let http = response as? HTTPURLResponse else { return Webhook.unreachable }
        return Webhook.problem(status: http.statusCode)
    }
}
