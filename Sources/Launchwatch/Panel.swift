import AppKit
import LaunchwatchCore
import SwiftUI

/// The whole panel, top to bottom: verdict, sites, the field to add one, settings.
struct PanelView: View {
    @ObservedObject var model: WatchModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
            if !model.sites.isEmpty {
                Hairline()
                SiteList(model: model)
                if let line = model.summaryLine {
                    Hairline()
                    SummaryRow(model: model, text: line)
                }
            }
            Hairline()
            AddField(model: model)
            Hairline()
            if model.showSettings {
                SettingsRows(model: model)
                    .transition(.soft)
                Hairline()
            }
            Footer(model: model)
        }
        .frame(width: Metrics.width)
        .background(Tone.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Tone.hairline))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: HeightKey.self, value: geometry.size.height)
        })
        .onPreferenceChange(HeightKey.self) { model.panelHeight = $0 }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: Header

private struct Header: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The verdict changing is the one thing worth noticing, so the words swap rather than snap.
            ZStack(alignment: .leading) {
                Text(model.verdict)
                    .font(Face.verdict)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .id(model.verdict)
                    .transition(.swap)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : Motion.swap, value: model.verdict)
            .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                if model.activity != nil, !model.sites.isEmpty { Spinner() }
                Text(subline)
                    .font(model.sites.isEmpty ? Face.body : Face.small)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, 15)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private var subline: String {
        if model.sites.isEmpty {
            return "Launchwatch checks your live sites every few minutes and tells you when one goes down, slows down, or changes in a way search engines notice."
        }
        if model.offline {
            let last = model.lastChecked.map { "Last checked \($0.ago(from: model.now)). " } ?? ""
            return "\(last)Checks resume once online."
        }
        if let activity = model.activity { return activity.words }
        let paused = model.sites.filter(\.isPaused).count
        if paused == model.sites.count { return "Nothing is being checked." }
        let checked = model.lastChecked.map { "Checked \($0.ago(from: model.now))" } ?? "Not checked yet"
        return paused == 0 ? checked : "\(checked), \(paused) paused"
    }
}

// MARK: Sites

private struct SiteList: View {
    @ObservedObject var model: WatchModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            rows
        } else {
            // Short lists sit at their own height; long ones scroll.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }.scrollIndicators(.automatic)
            }
            .frame(maxHeight: model.listLimit)
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.sites.enumerated()), id: \.element.id) { index, site in
                if index > 0 { Hairline(inset: Metrics.indent) }
                SiteRow(model: model, site: site)
            }
        }
    }
}

private struct SiteRow: View {
    @ObservedObject var model: WatchModel
    let site: SiteSummary
    private var isExpanded: Bool { model.expanded == site.id }
    private var isSelected: Bool { model.selected == site.id }

    var body: some View {
        VStack(spacing: 0) {
            Button { model.toggle(site.id, animated: true) } label: { summary }
                .buttonStyle(RowButton(highlighted: isSelected && !isExpanded))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(site.spoken)
                .accessibilityHint(isExpanded ? "Hides the details" : "Shows recent events and actions")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(named: "Open site") { model.open(site.id) }
                .accessibilityActions {
                    if site.isPaused {
                        Button("Resume") { model.resume(site.id) }
                    } else {
                        Button("Check now") { model.check(site.id) }
                        ForEach(PauseLength.allCases, id: \.self) { length in
                            Button(length.spoken) { model.pause(site.id, for: length) }
                        }
                    }
                    if model.canOpenReport { Button("Open report in Launchcheck") { model.openReport(site.id) } }
                }
                .accessibilityAction(named: "Remove") { model.remove(site.id) }
                .contextMenu {
                    if site.isPaused {
                        Button("Resume") { model.resume(site.id) }
                    } else {
                        Button("Check Now") { model.check(site.id) }
                        Menu("Pause") {
                            Button("For 1 Hour") { model.pause(site.id, for: .hour) }
                            Button("Until Tomorrow") { model.pause(site.id, for: .tomorrow) }
                            Button("Until Resumed") { model.pause(site.id, for: .untilResumed) }
                        }
                    }
                    Button("Open Site") { model.open(site.id) }
                    if model.canOpenReport { Button("Open Report in Launchcheck") { model.openReport(site.id) } }
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(site.site.url, forType: .string)
                    }
                    Divider()
                    Button("Remove \(site.site.host)", role: .destructive) { model.remove(site.id) }
                }
            if isExpanded {
                SiteDetail(model: model, site: site)
                    .transition(.soft)
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            StatusDot(condition: site.health.condition, muted: model.offline)
                .padding(.trailing, Metrics.dotGap)
            VStack(alignment: .leading, spacing: 2) {
                Text(site.site.host)
                    .font(isExpanded ? Face.addressStrong : Face.address)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = site.health.note, !model.offline || site.isPaused {
                    Text(note)
                        .font(Face.small)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Sparkline(buckets: site.buckets, muted: model.offline || site.isPaused)
                .frame(width: 72, height: 18)
            score
                .frame(width: 36, alignment: .trailing)
        }
        // A paused site steps back: still there, plainly not being watched.
        .opacity(site.isPaused ? 0.5 : 1)
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.row)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var score: some View {
        if let score = site.state.score {
            Text("\(score)")
                .font(Face.body)
                .monospacedDigit()
                .foregroundStyle(model.offline || site.isPaused ? .secondary : .primary)
        } else {
            // Not audited yet: an empty place for the score, not a zero.
            Circle()
                .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.25, dash: [2, 2.2]))
                .frame(width: 11, height: 11)
                .padding(.trailing, 2)
        }
    }
}

// MARK: Detail

private struct SiteDetail: View {
    @ObservedObject var model: WatchModel
    let site: SiteSummary
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var phraseDraft: String

    private static let eventsShown = 4

    init(model: WatchModel, site: SiteSummary) {
        self.model = model
        self.site = site
        _phraseDraft = State(initialValue: site.site.mustContain ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            timeline
            VStack(alignment: .leading, spacing: 9) {
                // The week first, then the figure that sums it up.
                if !site.strip.isEmpty {
                    UptimeStrip(cells: site.strip, width: Self.width, muted: model.offline)
                }
                HStack(alignment: .top, spacing: 0) {
                    fact(site.uptime.map(Words.percent) ?? "No data", "Uptime, 7 days")
                    fact(certificate, "Certificate until")
                    fact(domain, "Domain until")
                        .help(domainHelp)
                }
            }
            // The day: every response time kept, against the usual one.
            VStack(alignment: .leading, spacing: 5) {
                if site.chart.hasReadings {
                    ResponseChartView(chart: site.chart, width: Self.width, muted: model.offline)
                }
                HStack(spacing: 0) {
                    Text(site.chart.hasReadings ? "Response, 24 hours" : "No response times in the last 24 hours")
                    Spacer(minLength: 0)
                    if site.chart.median != nil {
                        Text("usual").frame(width: 44, alignment: .leading)
                    }
                }
                .font(Face.small)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
            // The audit: what it scored, then a way to read what it found, here or in Launchcheck.
            VStack(alignment: .leading, spacing: 9) {
                Text(auditLine)
                    .font(Face.small)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if site.state.score != nil {
                    HStack(spacing: 6) {
                        Button(showingIssues ? "Hide issues" : "See issues") { model.toggleIssues(site.id) }
                            .help("Read what the last audit found, without leaving the panel")
                        if model.canOpenReport {
                            Button("Open report") { model.openReport(site.id) }
                                .help("Open the full report for \(site.site.host) in Launchcheck")
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(QuietButton())
                    if showingIssues {
                        IssuesView(model: model, site: site, list: model.issues[site.id])
                            .transition(.soft)
                    }
                }
            }
            phrase
            // Checking, pausing and removing. Pausing and removing each ask one question before they act.
            HStack(spacing: 6) {
                if model.pausing == site.id {
                    ForEach(PauseLength.allCases, id: \.self) { length in
                        Button(length.title) { model.pause(site.id, for: length) }
                            .accessibilityLabel(length.spoken)
                            .help(length.hint)
                    }
                    Spacer(minLength: 0)
                    Button { model.pausing = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButton())
                        .help("Do not pause")
                        .accessibilityLabel("Do not pause")
                } else {
                    if site.isPaused {
                        Button("Resume") { model.resume(site.id) }
                            .help("Start checking \(site.site.host) again")
                    } else {
                        Button("Check now") { model.check(site.id) }
                            .disabled(model.isBusy)
                            .help("Check this site now")
                    }
                    Button("Open site") { model.open(site.id) }
                        .help("Open \(site.site.host) in the browser")
                    if !site.isPaused, model.confirmingRemoval != site.id {
                        Button("Pause") { model.pausing = site.id }
                            .help("Stop checking \(site.site.host) for a while")
                    }
                    Spacer(minLength: 0)
                    if model.confirmingRemoval == site.id {
                        Button("Stop watching") { model.remove(site.id) }
                            .accessibilityLabel("Confirm: stop watching \(site.site.host)")
                    } else {
                        Button("Remove") { model.confirmingRemoval = site.id }
                            .accessibilityLabel("Remove \(site.site.host)")
                    }
                }
            }
            .buttonStyle(QuietButton())
        }
        .padding(.leading, Metrics.indent)
        .padding(.trailing, Metrics.gutter)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { phraseDraft = site.site.mustContain ?? "" }
        .onChange(of: site.site.mustContain) { _, kept in phraseDraft = kept ?? "" }
    }

    private static let width = Metrics.width - Metrics.indent - Metrics.gutter
    private var showingIssues: Bool { model.showingIssues == site.id }

    /// The phrase the home page must show: a label, a field, and how the last look went.
    private var phrase: some View {
        HStack(spacing: 8) {
            Text("Must contain")
                .font(Face.small)
                .foregroundStyle(.secondary)
                .fixedSize()
            QuietField(label: "Must contain", prompt: "A phrase, like Add to cart", text: $phraseDraft,
                       commit: { model.setPhrase(site.id, phraseDraft) },
                       focusChanged: { model.fieldFocused = $0 })
            if let status = phraseStatus {
                Text(status)
                    .font(Face.small)
                    .foregroundStyle(site.state.missingPhrase == nil ? .secondary : .primary)
                    .fixedSize()
            }
        }
        .help("Report the site when its home page stops showing this phrase")
    }

    /// "Found", "Missing", or nothing while there is no phrase or it has not been looked for yet.
    private var phraseStatus: String? {
        guard site.site.mustContain != nil, Phrase.cleaned(phraseDraft) == site.site.mustContain else { return nil }
        if site.state.missingPhrase != nil { return "Missing" }
        guard let misses = site.state.phraseMisses else { return nil }
        return misses == 0 ? "Found" : "Not found"
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Face.bodyStrong)
                .monospacedDigit()
                .lineLimit(1)
            Text(label)
                .font(Face.small)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    private var certificate: String {
        guard let expiry = site.state.certificateExpiry else {
            return site.site.url.hasPrefix("http://") ? "No https" : "Not known"
        }
        return expiry.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// The day the registration runs out, or why there is no day to show.
    private var domain: String {
        if let expiry = site.state.domainExpiry { return expiry.formatted(.dateTime.day().month(.abbreviated).year()) }
        guard model.settings.domainExpiry, Domain.registrable(site.site.host) != nil else { return "Not checked" }
        return site.state.domainChecked == nil ? "Not checked yet" : "Not known"
    }

    private var domainHelp: String {
        guard let name = Domain.registrable(site.site.host) else { return "This address has no domain of its own to ask about" }
        guard model.settings.domainExpiry else { return "Domain expiry is switched off in the settings" }
        guard let checked = site.state.domainChecked else { return "The registry for \(name) has not been asked yet" }
        return site.state.domainExpiry == nil ? "The registry for \(name) gave no expiry date, asked \(checked.ago(from: model.now))"
                                              : "\(name), from its registry, asked \(checked.ago(from: model.now))"
    }

    private var auditLine: String {
        if case .auditing(let host) = model.activity, host == site.site.host { return "Running the audit now." }
        guard let audited = site.state.audited, let score = site.state.score else {
            return "Not audited yet. The first audit runs as soon as the site answers."
        }
        let pages = Words.count(site.state.pagesChecked ?? 0, "page", "pages")
        let blockers = site.state.blockers == 0 ? "nothing urgent" : Words.count(site.state.blockers, "thing to fix first", "things to fix first")
        return "Scored \(score) on \(pages), audited \(audited.ago(from: model.now)): \(blockers)."
    }

    @ViewBuilder private var timeline: some View {
        let events = Array(site.events.prefix(Self.eventsShown))
        if events.isEmpty {
            Text("Nothing has happened here yet.")
                .font(Face.small)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(Tone.of(event.level))
                            .frame(width: 6, height: 6)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.brief)
                                .font(Face.body)
                                .monospacedDigit()
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            // The likely cause, when the diagnosis found one: quieter, and under what it explains.
                            if let cause = event.cause {
                                Text(cause)
                                    .font(Face.small)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(event.date.ago(from: model.now))
                            .font(Face.small)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, index == events.count - 1 ? 0 : 9)
                    // The thread that makes it a timeline: a hairline from each dot down to the next.
                    .background(alignment: .topLeading) {
                        if index < events.count - 1 {
                            Tone.hairline.frame(width: 1).padding(.leading, 2.5).padding(.top, 14)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(event.brief) \(event.cause ?? "") \(event.date.ago(from: model.now))")
                }
            }
        }
    }
}

// MARK: Issues

/// What the last audit found, read in place: most serious first, one line each, and the detail of whichever is opened.
/// Everything here comes from the report Launchwatch keeps itself, so it reads the same with or without Launchcheck.
private struct IssuesView: View {
    @ObservedObject var model: WatchModel
    let site: SiteSummary
    let list: IssueList?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let list {
                if list.issues.isEmpty {
                    quiet("Nothing to fix. The last audit found no issues.")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.issues.enumerated()), id: \.element.id) { index, issue in
                            if index > 0 { Hairline() }
                            row(issue)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tone.hairline))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                HStack(spacing: 6) {
                    Button(model.copied == site.id ? "Copied" : "Copy as Markdown") { model.copyIssues(site.id) }
                        .help("Copy the whole list, to paste into a ticket or send to a client")
                    Spacer(minLength: 0)
                    if model.reportOffer == .getLaunchcheck {
                        Button("Get Launchcheck") { model.getLaunchcheck() }
                            .buttonStyle(QuietLink())
                            .help("Open the Launchcheck download page")
                    }
                }
                .buttonStyle(QuietButton())
                if model.reportOffer == .getLaunchcheck {
                    quiet(ReportOffer.pitch)
                }
            } else {
                quiet("Details appear after the next check.")
            }
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(Face.small)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ issue: Issue) -> some View {
        let open = model.openIssue == issue.id
        return VStack(alignment: .leading, spacing: 0) {
            Button { model.toggleIssue(issue.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(issue.level.map(Tone.of) ?? Color.secondary.opacity(0.6))
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                    Text(issue.title)
                        .font(open ? Face.bodyStrong : Face.body)
                        .lineLimit(open ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(issue.extent)
                        .font(Face.small)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(RowButton())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(issue.severityLabel): \(issue.title), \(issue.extent)")
            .accessibilityHint(open ? "Hides the detail" : "Shows why it matters and where it was found")
            .accessibilityAddTraits(.isButton)
            if open {
                detail(issue)
                    .transition(.soft)
            }
        }
    }

    private func detail(_ issue: Issue) -> some View {
        let places = issue.firstPlaces
        return VStack(alignment: .leading, spacing: 7) {
            Text(issue.why)
                .font(Face.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            (Text("Done when: ").font(Face.smallStrong) + Text(IssueList.sentence(issue.doneWhen)).font(Face.small))
                .fixedSize(horizontal: false, vertical: true)
            if !places.shown.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(places.shown.enumerated()), id: \.offset) { _, place in
                        Text(place)
                            .font(Face.address)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if places.more > 0 {
                        Text("and \(places.more) more")
                            .font(Face.small)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Weekly summary

/// Last week in one quiet line under the list. A week with nothing in it fits and just sits there;
/// a longer one is cut short and opens when clicked, the way a site row does.
private struct SummaryRow: View {
    @ObservedObject var model: WatchModel
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            words.lineLimit(1).fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Metrics.indent)
                .padding(.trailing, Metrics.gutter)
                .padding(.vertical, 11)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
            Button { model.toggleSummary(animated: true) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        if model.summaryOpen {
                            words.fixedSize(horizontal: false, vertical: true).lineSpacing(2).transition(.soft)
                        } else {
                            words.lineLimit(1).truncationMode(.tail).transition(.soft)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.summaryOpen ? 180 : 0))
                }
                .padding(.leading, Metrics.indent)
                .padding(.trailing, Metrics.gutter)
                .padding(.vertical, 11)
            }
            .buttonStyle(RowButton())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(model.summaryOpen ? "Folds the summary back to one line" : "Shows the whole summary")
        }
    }

    /// "Last week:" a touch stronger than what follows, so the eye can find the line and then leave it alone.
    private var words: Text {
        let label = "Last week:"
        // A host name should not break across lines at its hyphen.
        let rest = (text.hasPrefix(label) ? String(text.dropFirst(label.count)) : " " + text).replacingOccurrences(of: "-", with: "\u{2011}")
        return (Text(label).font(Face.smallStrong).foregroundStyle(.primary) + Text(rest).font(Face.small).foregroundStyle(.secondary))
            .monospacedDigit()
    }
}

// MARK: Add

private struct AddField: View {
    @ObservedObject var model: WatchModel
    @FocusState private var focused: Bool
    @Environment(\.isSnapshot) private var isSnapshot

    private static let prompt = "Add a site, like example.com"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if model.adding != nil { Spinner() } else {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: Metrics.dot)
                .padding(.trailing, Metrics.dotGap)
                .accessibilityHidden(true)

                if let adding = model.adding {
                    Text("Checking that \(adding) answers")
                        .font(Face.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if isSnapshot {
                    Text(model.draft.isEmpty ? Self.prompt : model.draft)
                        .font(model.draft.isEmpty ? Face.body : Face.address)
                        .foregroundStyle(model.draft.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(Self.prompt, text: $model.draft)
                        .textFieldStyle(.plain)
                        .font(model.draft.isEmpty ? Face.body : Face.address)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit { model.add() }
                        .accessibilityLabel("Add a site")
                        .accessibilityHint("Type an address and press Return")
                }
                if !model.draft.isEmpty, model.adding == nil {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .frame(height: 42)

            if let problem = model.addProblem {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Circle().fill(Tone.critical)
                        .frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                        .frame(width: Metrics.dot)
                        .padding(.trailing, Metrics.dotGap)
                    Text(problem)
                        .font(Face.small)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 13)
                .accessibilityElement(children: .combine)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onChange(of: model.focusRequest) { _, _ in focused = true }
        .onChange(of: model.draft) { _, _ in
            if model.addProblem != nil { model.addProblem = nil }
        }
    }
}

// MARK: Settings

private struct SettingsRows: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        VStack(spacing: 0) {
            line("Check uptime every") {
                Segments(label: "Check uptime every", choices: [(1, "1 min"), (5, "5 min"), (15, "15 min")],
                         selection: model.settings.pulseMinutes) { minutes in model.change { $0.pulseMinutes = minutes } }
            }
            line("Run the audit every") {
                Segments(label: "Run the audit every", choices: [(1, "1 h"), (6, "6 h"), (24, "24 h")],
                         selection: model.settings.auditHours) { hours in model.change { $0.auditHours = hours } }
            }
            line("Notify me when something changes") {
                Switch(label: "Notifications", isOn: model.settings.notifications) { model.change { $0.notifications.toggle() } }
            }
            line("Weekly summary on Mondays") {
                Switch(label: "Weekly summary on Mondays", isOn: model.settings.weeklySummary) { model.change { $0.weeklySummary.toggle() } }
            }
            line("Watch domain expiry") {
                Switch(label: "Watch domain expiry", isOn: model.settings.domainExpiry) { model.change { $0.domainExpiry.toggle() } }
            }
            .help("Once a day, asks rdap.org when each site's domain runs out")
            line("Open at login") {
                Switch(label: "Open at login", isOn: model.launchAtLogin) { model.setLaunchAtLogin(!model.launchAtLogin) }
            }
            line("Post events to a webhook") {
                Button("Send test") { model.sendTest() }
                    .buttonStyle(QuietButton())
                    .disabled(!model.webhookUsable || model.webhookSending)
                    .help("Post one test message to this address")
            }
            VStack(alignment: .leading, spacing: 7) {
                QuietField(label: "Webhook address", prompt: "Slack, Discord or any webhook address", text: $model.webhookDraft, font: Face.address,
                           commit: { model.commitWebhook() }, focusChanged: { model.fieldFocused = $0 })
                if let note = model.webhookLine {
                    Text(note)
                        .font(Face.small)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 8)
        }
        .padding(.vertical, 6)
    }

    private func line<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label).font(Face.body)
            Spacer()
            control()
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: 34)
    }
}

// MARK: Footer

private struct Footer: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        HStack(spacing: 2) {
            Button { model.toggleSettings(animated: true) } label: {
                Image(systemName: "gearshape")
                    .symbolVariant(model.showSettings ? .fill : .none)
            }
            .buttonStyle(IconButton())
            .help("Settings (\u{2318},)")
            .accessibilityLabel(model.showSettings ? "Hide settings" : "Settings")

            Button { model.checkAll() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButton())
                .disabled(model.sites.isEmpty || model.isBusy)
                .opacity(model.sites.isEmpty ? 0.35 : 1)
                .help("Check every site now (\u{2318}R)")
                .accessibilityLabel("Check every site now")

            Spacer()

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(FooterText())
                .help("Quit Launchwatch (\u{2318}Q)")
                .accessibilityLabel("Quit Launchwatch")
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(height: 38)
    }

    private struct FooterText: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Look(configuration: configuration)
        }

        struct Look: View {
            let configuration: Configuration
            @State private var hovering = false

            var body: some View {
                configuration.label
                    .font(Face.small)
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(configuration.isPressed ? Tone.lift : (hovering ? Tone.wash : .clear)))
                    .contentShape(Rectangle())
                    .scaleEffect(configuration.isPressed ? Metrics.press : 1)
                    .animation(Motion.press, value: configuration.isPressed)
                    .onHover { hovering = $0 }
            }
        }
    }
}

extension PauseLength {
    /// The whole instruction, for VoiceOver and menus where the button's own word is not enough.
    var spoken: String {
        switch self {
        case .hour: return "Pause for 1 hour"
        case .tomorrow: return "Pause until tomorrow"
        case .untilResumed: return "Pause until resumed"
        }
    }

    var hint: String {
        switch self {
        case .hour: return "Checks start again in an hour"
        case .tomorrow: return "Checks start again at \(PauseLength.morning):00 tomorrow"
        case .untilResumed: return "Checks stay off until you resume them"
        }
    }
}
