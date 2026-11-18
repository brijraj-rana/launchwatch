import Foundation
import LaunchcheckCore

/// One thing the last audit found wrong, with the places it found it.
public struct Issue: Equatable, Identifiable, Sendable {
    public var id: String
    public var severity: Severity
    public var title: String
    public var why: String
    /// How the same check reads once it passes: the line that says when the work is done.
    public var doneWhen: String
    /// Distinct pages it was found on. Zero when it is about the site as a whole.
    public var pages: Int
    /// Every place, as a short line: the page's path, then any detail.
    public var places: [String]

    public init(id: String, severity: Severity, title: String, why: String, doneWhen: String, pages: Int, places: [String]) {
        self.id = id
        self.severity = severity
        self.title = title
        self.why = why
        self.doneWhen = doneWhen
        self.pages = pages
        self.places = places
    }

    /// "3 pages", "1 page", or "Whole site" for something that is not about a page.
    public var extent: String {
        pages == 0 ? "Whole site" : Words.count(pages, "page", "pages")
    }

    /// "Fix before launch", "Should fix" or "Worth a look".
    public var severityLabel: String { severity.label }

    /// The severity as this app marks it: red, amber, or no mark of its own for what is only worth a look.
    public var level: Level? {
        switch severity {
        case .error: return .critical
        case .warning: return .warning
        case .notice: return nil
        }
    }

    public static let placesShown = 3

    /// The first few places, and how many are left unsaid.
    public var firstPlaces: (shown: [String], more: Int) {
        (Array(places.prefix(Self.placesShown)), max(0, places.count - Self.placesShown))
    }
}

/// What the last audit of a site found, ready to read in the panel or to send to someone.
/// Built from the report Launchwatch already keeps, so it needs nothing but this app.
public struct IssueList: Equatable, Sendable {
    public var host: String
    public var date: Date
    public var score: Int
    public var pagesChecked: Int
    /// Most serious first, in the order a Launchcheck report lists them.
    public var issues: [Issue]

    public init(host: String, date: Date, score: Int, pagesChecked: Int, issues: [Issue]) {
        self.host = host
        self.date = date
        self.score = score
        self.pagesChecked = pagesChecked
        self.issues = issues
    }

    public init(_ report: Report) {
        let issues = report.groups.map { group -> Issue in
            let pages = Set(group.findings.compactMap(\.url)).count
            let places = group.findings.map { ReportFormat.line($0, site: report.site) }.filter { !$0.isEmpty }
            return Issue(id: group.check.id, severity: group.check.severity, title: group.check.title, why: group.check.why,
                         doneWhen: group.check.passed, pages: pages, places: places)
        }
        self.init(host: report.host, date: report.date, score: report.score, pagesChecked: report.pagesChecked, issues: issues)
    }

    public func count(_ severity: Severity) -> Int {
        issues.filter { $0.severity == severity }.count
    }

    /// "3 to fix first, 4 to tidy, 2 worth a look", leaving out what there is none of.
    public var tally: String {
        var parts: [String] = []
        if count(.error) > 0 { parts.append("\(count(.error)) to fix first") }
        if count(.warning) > 0 { parts.append("\(count(.warning)) to tidy") }
        if count(.notice) > 0 { parts.append("\(count(.notice)) worth a look") }
        return parts.isEmpty ? "Nothing to fix" : parts.joined(separator: ", ")
    }

    /// Most places listed under one issue in the Markdown; a client does not need four hundred lines of one fault.
    public static let placesInMarkdown = 20

    /// The whole list as Markdown, to paste into a ticket or send to a client.
    public var markdown: String {
        var lines = ["# Issues on \(host)", "",
                     "Score \(score) of 100. \(Words.count(pagesChecked, "page", "pages")) checked on \(Diagnosis.day(date)).", ""]
        if issues.isEmpty {
            lines += ["Nothing to fix: the last audit found no issues.", ""]
        }
        for severity in Severity.allCases {
            let group = issues.filter { $0.severity == severity }
            guard !group.isEmpty else { continue }
            lines += ["## \(severity.label)", ""]
            for issue in group {
                lines += ["### \(issue.title) (\(issue.extent.prefix(1).lowercased() + issue.extent.dropFirst()))", "", issue.why, "",
                          "Done when: \(Self.sentence(issue.doneWhen))", ""]
                let shown = issue.places.prefix(Self.placesInMarkdown)
                lines += shown.map { "- \(Self.escaped($0))" }
                if issue.places.count > shown.count { lines.append("- and \(issue.places.count - shown.count) more") }
                if !shown.isEmpty { lines.append("") }
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
    }

    /// With a full stop, once.
    public static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?".contains(last) ? text : text + "."
    }

    /// An address or a page title may hold characters Markdown would read as markup.
    static func escaped(_ text: String) -> String {
        var out = ""
        for character in text {
            if "*_`<>[]|".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

/// What the issues view offers next to its own list. Launchwatch is whole without Launchcheck; this only decides
/// whether to open the report there or to say, quietly and only here, that it exists.
public enum ReportOffer: Equatable, Sendable {
    case openReport
    case getLaunchcheck

    public static func of(_ schemes: SchemeChecking) -> ReportOffer {
        ReportLink.available(schemes) ? .openReport : .getLaunchcheck
    }

    /// Where Launchcheck can be had.
    public static let download = URL(string: "https://github.com/BRIJRAJ-02/launchcheck/releases/latest")!
    public static let pitch = "Launchcheck adds the full report, page by page."
}
