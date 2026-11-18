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
            }
            Hairline()
            AddField(model: model)
            Hairline()
            if model.showSettings {
                SettingsRows(model: model)
                    .transition(.opacity)
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
            Text(model.verdict)
                .font(Face.verdict)
                .lineLimit(1)
                .truncationMode(.middle)
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
        return model.lastChecked.map { "Checked \($0.ago(from: model.now))" } ?? "Not checked yet"
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
                .accessibilityAction(named: "Check now") { model.check(site.id) }
                .accessibilityAction(named: "Open site") { model.open(site.id) }
                .accessibilityAction(named: "Remove") { model.remove(site.id) }
                .contextMenu {
                    Button("Check Now") { model.check(site.id) }
                    Button("Open Site") { model.open(site.id) }
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(site.site.url, forType: .string)
                    }
                    Divider()
                    Button("Remove \(site.site.host)", role: .destructive) { model.remove(site.id) }
                }
            if isExpanded {
                SiteDetail(model: model, site: site)
                    .transition(.opacity)
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
                if let note = site.health.note, !model.offline {
                    Text(note)
                        .font(Face.small)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Sparkline(buckets: site.buckets, muted: model.offline)
                .frame(width: 72, height: 18)
            score
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.gutter)
        .frame(height: Metrics.row)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var score: some View {
        if let score = site.state.score {
            Text("\(score)")
                .font(Face.body)
                .monospacedDigit()
                .foregroundStyle(model.offline ? .secondary : .primary)
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

    private static let eventsShown = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            timeline
            HStack(alignment: .top, spacing: 0) {
                fact(site.uptime.map(Words.percent) ?? "No data", "Uptime, 7 days")
                fact(site.median.map(Words.time) ?? "No data", "Usual response")
                fact(certificate, "Certificate until")
            }
            Text(auditLine)
                .font(Face.small)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Check now") { model.check(site.id) }
                    .disabled(model.isBusy)
                    .help("Check this site now")
                Button("Open site") { model.open(site.id) }
                    .help("Open \(site.site.host) in the browser")
                Spacer()
                if model.confirmingRemoval == site.id {
                    Button("Stop watching") { model.remove(site.id) }
                        .accessibilityLabel("Confirm: stop watching \(site.site.host)")
                } else {
                    Button("Remove") { model.confirmingRemoval = site.id }
                        .accessibilityLabel("Remove \(site.site.host)")
                }
            }
            .buttonStyle(QuietButton())
        }
        .padding(.leading, Metrics.indent)
        .padding(.trailing, Metrics.gutter)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        Text(event.brief)
                            .font(Face.body)
                            .monospacedDigit()
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
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
                    .accessibilityLabel("\(event.brief) \(event.date.ago(from: model.now))")
                }
            }
        }
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
            line("Open at login") {
                Switch(label: "Open at login", isOn: model.launchAtLogin) { model.setLaunchAtLogin(!model.launchAtLogin) }
            }
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
