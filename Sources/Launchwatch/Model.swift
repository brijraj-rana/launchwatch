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
    @Published var now = Date()

    @Published var expanded: UUID?
    @Published var selected: UUID?
    @Published var confirmingRemoval: UUID?
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
    /// The height the panel draws at, so the window knows which clicks are outside it.
    var panelHeight: CGFloat = 0
    /// False when the system says there is no network at all.
    var online = true

    private let watcher: Watcher?
    private var queue: Task<Void, Never>?
    private var waiting = 0

    init(watcher: Watcher?) {
        self.watcher = watcher
        if Notifier.inBundle { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    // MARK: Derived

    var verdict: String { Verdict.line(sites, offline: offline) }

    var isBusy: Bool { activity != nil || adding != nil }

    /// The most serious condition of any site, for the menu bar dot.
    var attention: Health.Condition? {
        guard !offline else { return nil }
        return sites.map(\.health.condition).filter { $0 == .critical || $0 == .warning }.min()
    }

    var attentionCount: Int {
        offline ? 0 : sites.filter(\.health.needsAttention).count
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
        settings = await watcher.settings
        lastChecked = await watcher.lastChecked()
        now = Date()
        if let expanded, !sites.contains(where: { $0.id == expanded }) { self.expanded = nil }
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
        let due = everything ? entries.map(\.site.id) : await watcher.pulsesDue()
        if !due.isEmpty {
            let host = entries.first { $0.site.id == due[0] }?.site.host ?? ""
            activity = .checking(due.count == 1 ? host : "\(due.count) sites")
            let outcome = await watcher.pulse(due)
            offline = outcome.offline && outcome.pulsed == 0
            announce(outcome.events)
            await refresh()
        }
        if !offline {
            for id in await watcher.auditsDue() {
                guard let host = sites.first(where: { $0.id == id })?.site.host else { continue }
                activity = .auditing(host)
                announce(await watcher.audit(id))
                await refresh()
            }
        }
        activity = nil
    }

    /// Pulses and audits one site now.
    func check(_ id: UUID) {
        enqueue { [weak self] in
            guard let self, let watcher = self.watcher, let host = self.sites.first(where: { $0.id == id })?.site.host else { return }
            self.activity = .checking(host)
            let outcome = await watcher.pulse([id])
            self.offline = outcome.offline
            self.announce(outcome.events)
            await self.refresh()
            if !outcome.offline, self.sites.first(where: { $0.id == id })?.state.failures == 0 {
                self.activity = .auditing(host)
                self.announce(await watcher.audit(id))
                await self.refresh()
            }
            self.activity = nil
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

    // MARK: Panel state

    /// Opens or closes a row. Clicks animate; the keyboard does not.
    func toggle(_ id: UUID, animated: Bool) {
        let opening = expanded != id
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let change = {
            self.expanded = opening ? id : nil
            self.confirmingRemoval = nil
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
        addProblem = nil
        now = Date()
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
