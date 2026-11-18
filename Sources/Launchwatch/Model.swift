import AppKit
import LaunchwatchCore
import ServiceManagement
import SwiftUI

/// What the panel shows and what it can do. The watcher does the work; this keeps the screen in step with it.
@MainActor
final class WatchModel: ObservableObject {
    enum Activity: Equatable {
        case checking(String)       // "acme-rockets.com" or "6 sites"
        case auditing(String)

        var words: String {
            switch self {
            case .checking(let what): return "Checking \(what)"
            case .auditing(let host): return "Auditing \(host)"
            }
        }
    }

    @Published var sites: [SiteSummary] = []
    @Published var settings = WatchSettings()
    @Published var offline = false
    @Published var activity: Activity?
    @Published var lastChecked: Date?
    /// The latest weekly summary, however old.
    @Published var summary: WeekSummary?
    /// True when the summary line shows all of itself.
    @Published var summaryOpen = false
    /// True when some app on this Mac opens launchcheck links.
    @Published var canOpenReport = false
    /// The site whose issues are being read in its open row.
    @Published var showingIssues: UUID?
    /// The issue opened within that list.
    @Published var openIssue: String?
    /// What the last audit found, for the sites whose list has been asked for. A site with no entry has no report kept yet.
    @Published var issues: [UUID: IssueList] = [:]
    @Published var now = Date()

    @Published var expanded: UUID?
    @Published var selected: UUID?
    @Published var confirmingRemoval: UUID?
    /// The site whose row is asking how long to pause for.
    @Published var pausing: UUID?
    /// True while a field inside the panel, other than the address field, has the keyboard.
    @Published var fieldFocused = false

    /// The webhook address as it stands in the field, kept or not.
    @Published var webhookDraft = ""
    /// What became of the last message sent to the webhook, when that is worth saying.
    @Published var webhookNote: String?
    @Published var webhookSending = false
    @Published var showSettings = false
    @Published var launchAtLogin = false

    @Published var draft = ""
    @Published var adding: String?
    @Published var addProblem: String?
    /// Changes whenever the address field should take the keyboard.
    @Published var focusRequest = 0
    /// The tallest the list may grow before it scrolls. Set from the screen the panel opens on.
    @Published var listLimit: CGFloat = 460

    /// Called with events that are new, for notifications.
    var announce: ([SiteEvent]) -> Void = { _ in }
    /// Called with a weekly summary the moment it is written.
    var announceSummary: (WeekSummary) -> Void = { _ in }
    /// The height the panel draws at, so the window knows which clicks are outside it.
    var panelHeight: CGFloat = 0
    /// False when the system says there is no network at all.
    var online = true

    private let watcher: Watcher?
    private let schemes: SchemeChecking
    private let poster: WebhookPosting = URLSessionWebhook()
    private var queue: Task<Void, Never>?
    private var waiting = 0

    init(watcher: Watcher?, schemes: SchemeChecking) {
        self.watcher = watcher
        self.schemes = schemes
        canOpenReport = ReportLink.available(schemes)
        if Notifier.inBundle { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    // MARK: Derived

    var verdict: String { Verdict.line(sites, offline: offline) }

    var isBusy: Bool { activity != nil || adding != nil }

    /// The most serious condition of any site, for the menu bar dot.
    /// A paused site is neither, so it never lights the dot.
    var attention: Health.Condition? {
        guard !offline else { return nil }
        return sites.map(\.health.condition).filter { $0 == .critical || $0 == .warning }.min()
    }

    var attentionCount: Int {
        offline ? 0 : sites.filter(\.health.needsAttention).count
    }

    /// The summary as the panel shows it, or nil when it is switched off, there is nothing to watch,
    /// or the latest one is too old to be called last week.
    var summaryLine: String? {
        guard settings.weeklySummary, !sites.isEmpty, let summary else { return nil }
        let age = now.timeIntervalSince(summary.date)
        guard age < 7 * 86_400 + 3600 else { return nil }
        return summary.text(now: max(now, summary.date))
    }

    // MARK: Work

    /// Runs one piece of work after whatever is already running, so checks never overlap.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        waiting += 1
        queue = Task { [weak self] in
            await previous?.value
            await work()
            self?.waiting -= 1
        }
    }

    func load() {
        enqueue { [weak self] in await self?.refresh() }
    }

    func refresh() async {
        guard let watcher else { return }
        sites = await watcher.summaries()
        let kept = settings.webhook ?? ""
        settings = await watcher.settings
        // The field follows what is kept, unless someone is in the middle of changing it.
        if webhookDraft == kept { webhookDraft = settings.webhook ?? "" }
        lastChecked = await watcher.lastChecked()
        summary = await watcher.summary
        now = Date()
        if let expanded, !sites.contains(where: { $0.id == expanded }) { self.expanded = nil }
        // A list that is open follows the audit it was read from.
        if let showingIssues {
            if sites.contains(where: { $0.id == showingIssues }) { issues[showingIssues] = await watcher.issues(for: showingIssues) } else { self.showingIssues = nil }
        }
        if let selected, !sites.contains(where: { $0.id == selected }) { self.selected = nil }
    }

    /// Called on a timer, on wake and when the network comes back: runs whatever has fallen due.
    func tick() {
        guard waiting == 0 else { return }
        enqueue { [weak self] in await self?.runDue(everything: false) }
    }

    /// Checks every site now, whether or not it is due.
    func checkAll() {
        enqueue { [weak self] in await self?.runDue(everything: true) }
    }

    private func runDue(everything: Bool) async {
        guard let watcher, !sites.isEmpty || everything else { return }
        guard online else {
            offline = !sites.isEmpty
            return
        }
        let entries = await watcher.entries
        let due = everything ? entries.filter { !Pausing.isPaused($0.state, now: Date()) }.map(\.site.id) : await watcher.pulsesDue()
        if !due.isEmpty {
            let host = entries.first { $0.site.id == due[0] }?.site.host ?? ""
            activity = .checking(due.count == 1 ? host : "\(due.count) sites")
            let outcome = await watcher.pulse(due)
            offline = outcome.offline && outcome.pulsed == 0
            tell(outcome.events)
            await refresh()
        }
        if !offline {
            // After the pulses, so the week is summed up with this morning in it; before the audits, which take minutes.
            if let summary = await watcher.weeklySummaryIfDue() {
                self.summary = summary
                announceSummary(summary)
                deliver([Webhook.Message(summary)])
            }
            // The registry, once a day for each site. One short request, so it says nothing about itself in the header.
            let domains = await watcher.domainsDue()
            for id in domains { tell(await watcher.checkDomain(id)) }
            if !domains.isEmpty { await refresh() }
            for id in await watcher.auditsDue() {
                guard let host = sites.first(where: { $0.id == id })?.site.host else { continue }
                activity = .auditing(host)
                tell(await watcher.audit(id))
                await refresh()
            }
        }
        activity = nil
    }

    /// Pulses and audits one site now.
    func check(_ id: UUID) {
        enqueue { [weak self] in
            guard let self, let watcher = self.watcher, let site = self.sites.first(where: { $0.id == id }), !site.isPaused else { return }
            let host = site.site.host
            self.activity = .checking(host)
            let outcome = await watcher.pulse([id])
            self.offline = outcome.offline
            self.tell(outcome.events)
            await self.refresh()
            if !outcome.offline, self.sites.first(where: { $0.id == id })?.state.failures == 0 {
                self.activity = .auditing(host)
                self.tell(await watcher.audit(id))
                await self.refresh()
            }
            self.activity = nil
        }
    }

    /// One pulse of one site, after something about it changed.
    private func pulseSoon(_ id: UUID, after change: @escaping (Watcher) async -> Void) {
        enqueue { [weak self] in
            guard let self, let watcher = self.watcher else { return }
            await change(watcher)
            await self.refresh()
            guard self.online, let site = self.sites.first(where: { $0.id == id }), !site.isPaused else { return }
            self.activity = .checking(site.site.host)
            let outcome = await watcher.pulse([id])
            self.tell(outcome.events)
            await self.refresh()
            self.activity = nil
        }
    }

    // MARK: Pausing

    func pause(_ id: UUID, for length: PauseLength) {
        pausing = nil
        guard let watcher else { return }
        Task {
            await watcher.pause(id, for: length)
            await refresh()
        }
    }

    /// Ends a pause and looks at the site straight away.
    func resume(_ id: UUID) {
        pulseSoon(id) { await $0.resume(id) }
    }

    // MARK: Must contain

    /// Keeps the phrase a site's home page must show, and looks for it at once. An empty phrase asks nothing.
    func setPhrase(_ id: UUID, _ phrase: String) {
        guard let site = sites.first(where: { $0.id == id }), Phrase.cleaned(phrase) != site.site.mustContain else { return }
        pulseSoon(id) { await $0.setPhrase(id, phrase) }
    }

    // MARK: Webhook

    /// Says the new events here, and to the channel if there is one.
    private func tell(_ events: [SiteEvent]) {
        guard !events.isEmpty else { return }
        announce(events)
        deliver(events.map { Webhook.Message($0) })
    }

    /// Posts to the webhook, one message after another, without holding anything else up. A message that does not
    /// arrive is not tried again; Settings says so, until one arrives.
    private func deliver(_ messages: [Webhook.Message]) {
        let address = settings.webhook
        let requests = messages.compactMap { Webhook.request(to: address, $0) }
        guard !requests.isEmpty else { return }
        Task {
            for request in requests {
                let problem = await poster.post(request)
                webhookNote = problem.map { "Last event was not delivered. \($0)" }
            }
        }
    }

    /// Keeps what is in the webhook field. An empty field means no webhook, and nothing is sent anywhere.
    func commitWebhook() {
        let text = webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != (settings.webhook ?? "") else { return }
        webhookNote = nil
        change { $0.webhook = text.isEmpty ? nil : text }
    }

    /// True when what is in the field is an address a message could go to.
    var webhookUsable: Bool { Webhook.url(from: webhookDraft) != nil }

    func sendTest() {
        commitWebhook()
        guard !webhookSending, let request = Webhook.request(to: settings.webhook, .test(now: Date())) else { return }
        webhookSending = true
        webhookNote = nil
        Task {
            let problem = await poster.post(request)
            webhookSending = false
            webhookNote = problem ?? "Test sent."
        }
    }

    /// The quiet line under the webhook field.
    var webhookLine: String? {
        let text = webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard let url = Webhook.url(from: text) else { return "That does not look like a web address." }
        if webhookSending { return "Sending a test." }
        if let webhookNote { return webhookNote }
        switch Webhook.flavor(of: url) {
        case .slack: return "Every event is posted as a Slack message."
        case .discord: return "Every event is posted as a Discord message."
        case .plain: return "Every event is posted as JSON."
        }
    }

    func add() {
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, adding == nil, let watcher else { return }
        addProblem = nil
        adding = input.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        Task {
            let outcome = await watcher.add(input)
            adding = nil
            if case .added(let site) = outcome {
                draft = ""
                await refresh()
                selected = site.id
                Notifier.ask()
                check(site.id)        // the first audit, straight away
            } else {
                addProblem = outcome.sentence
                focusRequest += 1
            }
        }
    }

    func remove(_ id: UUID) {
        guard let watcher else { return }
        confirmingRemoval = nil
        pausing = nil
        if expanded == id { expanded = nil }
        Task {
            await watcher.remove(id)
            await refresh()
        }
    }

    func open(_ id: UUID) {
        guard let address = sites.first(where: { $0.id == id })?.site.url, let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Issues

    /// Opens or closes the list of what the last audit found, read from the report kept on this Mac.
    func toggleIssues(_ id: UUID) {
        let opening = showingIssues != id
        openIssue = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let change = { self.showingIssues = opening ? id : nil }
        if reduceMotion { change() } else { withAnimation(opening ? Motion.expand : Motion.collapse, change) }
        if opening { loadIssues(id) }
    }

    private func loadIssues(_ id: UUID) {
        guard let watcher else { return }
        Task { issues[id] = await watcher.issues(for: id) }
    }

    func toggleIssue(_ id: String) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let change = { self.openIssue = self.openIssue == id ? nil : id }
        if reduceMotion { change() } else { withAnimation(openIssue == id ? Motion.collapse : Motion.expand, change) }
    }

    func copyIssues(_ id: UUID) {
        guard let list = issues[id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(list.markdown, forType: .string)
        copied = id
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copied == id { copied = nil }
        }
    }

    /// The site whose issues were just copied, so its button can say so for a moment.
    @Published var copied: UUID?

    /// What sits beside the issue list: the way into Launchcheck, or a quiet word that it exists.
    var reportOffer: ReportOffer { canOpenReport ? .openReport : .getLaunchcheck }

    func getLaunchcheck() {
        NSWorkspace.shared.open(ReportOffer.download)
    }

    func openReport(_ id: UUID) {
        guard canOpenReport, let site = sites.first(where: { $0.id == id })?.site, let url = ReportLink.url(for: site) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Panel state

    /// Shows the whole summary or folds it back to one line. Clicks animate; nothing else does.
    func toggleSummary(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated, !reduceMotion {
            withAnimation(summaryOpen ? Motion.collapse : Motion.expand) { summaryOpen.toggle() }
        } else {
            summaryOpen.toggle()
        }
    }

    /// Opens or closes a row. Clicks animate; the keyboard does not.
    func toggle(_ id: UUID, animated: Bool) {
        let opening = expanded != id
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let change = {
            self.expanded = opening ? id : nil
            self.confirmingRemoval = nil
            self.pausing = nil
            if self.showingIssues != id || !opening { self.showingIssues = nil }
            self.openIssue = nil
        }
        selected = id
        if animated, !reduceMotion {
            withAnimation(opening ? Motion.expand : Motion.collapse, change)
        } else {
            change()
        }
    }

    func moveSelection(_ step: Int) {
        guard !sites.isEmpty else { return }
        guard let selected, let index = sites.firstIndex(where: { $0.id == selected }) else {
            self.selected = step > 0 ? sites.first?.id : sites.last?.id
            return
        }
        self.selected = sites[min(sites.count - 1, max(0, index + step))].id
    }

    func toggleSettings(animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated, !reduceMotion {
            withAnimation(showSettings ? Motion.collapse : Motion.expand) { showSettings.toggle() }
        } else {
            showSettings.toggle()
        }
    }

    /// Back to a tidy panel, ready for the next time it opens.
    func settle() {
        confirmingRemoval = nil
        pausing = nil
        fieldFocused = false
        addProblem = nil
        summaryOpen = false
        now = Date()
        // Launchcheck may have been installed or removed since the panel was last open.
        canOpenReport = ReportLink.available(schemes)
    }

    // MARK: Settings

    func change(_ edit: (inout WatchSettings) -> Void) {
        edit(&settings)
        let settings = self.settings
        guard let watcher else { return }
        Task {
            await watcher.set(settings)
            tick()
        }
        if settings.notifications { Notifier.ask() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard Notifier.inBundle else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
