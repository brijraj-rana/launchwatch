import AppKit
import Combine
import LaunchwatchCore
import Network
import SwiftUI
import UserNotifications

// MARK: Notifications

/// Notifications need a real app bundle. Run from `swift run` or in snapshot mode, every call here does nothing.
enum Notifier {
    static var inBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static func ask() {
        guard inBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ event: SiteEvent) {
        guard inBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = event.host
        content.body = event.full
        content.userInfo = ["site": event.site.uuidString]
        if event.level == .critical { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil))
    }

    /// The weekly summary: one quiet notification, no sound.
    static func post(_ summary: WeekSummary) {
        guard inBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = "Last week"
        content.body = summary.body(now: summary.date)
        content.userInfo = ["summary": true]
        // Always the same identifier, so Notification Center holds the latest summary and never a pile of them.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "weekly-summary", content: content, trigger: nil))
    }
}

/// Asks the system whether any app opens a link.
struct WorkspaceSchemes: SchemeChecking {
    func hasApp(for url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }
}

// MARK: Menu bar glyph

enum Glyph {
    /// Five readings in a row, one of them missing: the same picture as the app icon, at menu bar size.
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let heights: [CGFloat] = [7, 11, 3, 9, 12]
            let width: CGFloat = 2.2, gap: CGFloat = 1.4
            let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
            var x = (18 - total) / 2
            NSColor.black.setFill()
            for height in heights {
                NSBezierPath(roundedRect: NSRect(x: x, y: 3, width: width, height: height), xRadius: width / 2, yRadius: width / 2).fill()
                x += width + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Launchwatch"
        return image
    }
}

// MARK: Window

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // The shadow margin may hang off the edge of the screen; AppKit would otherwise push the window back on.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class StatusController: NSObject, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let model: WatchModel
    private var item: NSStatusItem!
    private var badge: NSView!
    private var panel: Panel!
    private var visibleRect = NSRect.zero
    private var monitors: [Any] = []
    private var watchers: Set<AnyCancellable> = []
    private var timer: Timer?
    private var closedAt = Date.distantPast
    private let path = NWPathMonitor()

    private static let windowHeight: CGFloat = 900

    override init() {
        let directory = ProcessInfo.processInfo.environment["LAUNCHWATCH_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        model = WatchModel(watcher: Watcher(store: Store(directory: directory ?? Store.defaultDirectory)), schemes: WorkspaceSchemes())
        super.init()
    }

    func start() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Glyph.image()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.setAccessibilityLabel("Launchwatch")

            badge = NSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 3
            badge.isHidden = true
            button.addSubview(badge)
        }

        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: Metrics.width + Metrics.margin * 2, height: Self.windowHeight),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self
        let host = NSHostingView(rootView: PanelRoot(model: model))
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = host

        // Keep the menu bar item in step with the sites.
        model.$sites.combineLatest(model.$offline).receive(on: RunLoop.main).sink { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateBadge() }
        }.store(in: &watchers)

        model.announce = { [weak model] events in
            guard let model, model.settings.notifications else { return }
            events.forEach(Notifier.post)
        }
        model.announceSummary = { [weak model] summary in
            guard let model, model.settings.notifications else { return }
            Notifier.post(summary)
        }
        if Notifier.inBundle { UNUserNotificationCenter.current().delegate = self }

        // The network going away is not every site going down; coming back is a reason to look again.
        path.pathUpdateHandler = { [weak self] update in
            let online = update.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let was = self.model.online
                    self.model.online = online
                    if !online, !self.model.sites.isEmpty { self.model.offline = true }
                    if online, !was || self.model.offline { self.model.tick() }
                }
            }
        }
        path.start(queue: DispatchQueue(label: "launchwatch.network"))

        // The timer only asks "is anything due?", measured against the wall clock, so a Mac that slept
        // through three checks runs one as soon as it wakes instead of waiting out a stale countdown.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Give the network a moment to come back before judging anyone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                MainActor.assumeIsolated { self?.model.tick() }
            }
        }

        Task {
            await model.refresh()
            if !model.sites.isEmpty, model.settings.notifications { Notifier.ask() }
            model.tick()
        }
    }

    // MARK: Menu bar item

    private func updateBadge() {
        guard let button = item.button else { return }
        let attention = model.attention
        badge.isHidden = attention == nil
        badge.layer?.backgroundColor = (attention == .critical ? NSColor.systemRed : NSColor.systemOrange).cgColor
        // A number appears only when more than one site is in trouble.
        let count = model.attentionCount
        button.title = count > 1 ? " \(count)" : ""
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        button.layoutSubtreeIfNeeded()
        let image = button.cell.map { $0.imageRect(forBounds: button.bounds) } ?? button.bounds
        badge.frame = NSRect(x: image.maxX - 4, y: button.isFlipped ? image.minY - 1 : image.maxY - 5, width: 6, height: 6)

        var spoken = "Launchwatch"
        if count > 0 { spoken += ", \(model.verdict)" }
        button.setAccessibilityLabel(spoken)
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseDown {
            closePanel()
            let menu = NSMenu()
            menu.addItem(withTitle: "Check Now", action: #selector(checkNow), keyEquivalent: "r").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Launchwatch", action: #selector(quit), keyEquivalent: "q").target = self
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else if panel.isVisible {
            closePanel()
        } else if Date().timeIntervalSince(closedAt) > 0.25 {
            openPanel()
        }
    }

    @objc private func checkNow() { model.checkAll() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Panel

    func openPanel(showing site: UUID? = nil, summary: Bool = false) {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let area = screen.visibleFrame

        model.settle()
        model.listLimit = max(184, min(460, area.height - 330))
        if let site { model.expanded = site; model.selected = site }
        if summary { model.summaryOpen = true }

        let x = min(max(anchor.midX - Metrics.width / 2, area.minX + 8), area.maxX - Metrics.width - 8)
        let top = anchor.minY - 5
        visibleRect = NSRect(x: x, y: top - Self.windowHeight, width: Metrics.width, height: Self.windowHeight)
        panel.setFrame(NSRect(x: x - Metrics.margin, y: top + Metrics.margin - Self.windowHeight,
                              width: Metrics.width + Metrics.margin * 2, height: Self.windowHeight), display: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)

        // With nothing to watch the field is the only thing to do, so it takes the keyboard. Otherwise the arrow keys walk the list.
        if model.sites.isEmpty {
            model.focusRequest += 1
        } else {
            panel.makeFirstResponder(nil)
        }

        Task { await model.refresh() }
        installMonitors()
    }

    func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        item.button?.highlight(false)
        closedAt = Date()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }) { monitors.append(outside) }

        // The window is taller than what it draws. A click below the panel belongs to whatever is underneath.
        if let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let mine = event.window === self?.panel
            let place = event.locationInWindow
            let swallowed = MainActor.assumeIsolated { () -> Bool in
                guard let self, mine else { return false }
                let point = self.panel.convertPoint(toScreen: place)
                let drawn = NSRect(x: self.visibleRect.minX, y: self.visibleRect.maxY - self.model.panelHeight,
                                   width: self.visibleRect.width, height: self.model.panelHeight)
                guard !drawn.contains(point) else { return false }
                self.closePanel()
                return true
            }
            return swallowed ? nil : event
        }) { monitors.append(inside) }

        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags
            let handled = MainActor.assumeIsolated { self?.handle(keyCode: code, flags: flags) ?? false }
            return handled ? nil : event
        }) { monitors.append(keys) }
    }

    /// Keyboard: arrows walk the list, Return opens a row, Esc closes. Nothing here animates. True when the key was used.
    private func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard panel.isKeyWindow else { return false }
        let command = flags.intersection(.deviceIndependentFlagsMask) == .command
        let plain = flags.intersection([.command, .option, .control]).isEmpty
        let typing = panel.firstResponder is NSTextView

        switch keyCode {
        case 53 where plain:                                   // Esc
            closePanel()
        case 125 where plain:                                  // down
            if typing, model.fieldFocused { return false }
            model.moveSelection(1)
        case 126 where plain:                                  // up
            if typing, model.fieldFocused { return false }
            model.moveSelection(-1)
        case 36 where plain, 76 where plain:                   // Return
            // In a field, Return belongs to the field: it keeps the phrase or the webhook, and does not fold the row.
            if typing, !model.draft.isEmpty || model.fieldFocused { return false }
            guard let selected = model.selected else { return false }
            model.toggle(selected, animated: false)
        case 15 where command:                                 // R
            model.checkAll()
        case 43 where command:                                 // comma
            model.toggleSettings(animated: false)
        case 45 where command:                                 // N
            model.focusRequest += 1
        case 12 where command:                                 // Q
            NSApp.terminate(nil)
        default:
            return false
        }
        return true
    }

    // MARK: Notification clicks

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let site = (info["site"] as? String).flatMap(UUID.init)
        let summary = info["summary"] as? Bool ?? false
        await MainActor.run { self.openPanel(showing: site, summary: summary) }
    }
}

/// The panel inside its oversized, see-through window: pinned to the top, with room around it for the shadow.
struct PanelRoot: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        PanelView(model: model)
            .background(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).fill(Tone.surface)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8))
            .padding(Metrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let directory = value(after: "--snapshot") {
            Snapshot.render(to: directory, scale: value(after: "--scale").flatMap(Double.init).map { CGFloat($0) } ?? 2)
        } else if let address = value(after: "--pulse") {
            Self.pulseOnce(address)
        } else if args.contains("--summary") {
            Self.summaryOnce()
        } else {
            NSApp.mainMenu = Self.mainMenu()
            let controller = StatusController()
            controller.start()
            self.controller = controller
        }
    }

    /// Opening the app again while it is running shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.openPanel()
        return false
    }

    /// Never shown, since the app has no menu bar of its own, but it is what makes Cut, Copy and Paste work in the address field.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit Launchwatch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(app)

        let edit = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = menu
        main.addItem(edit)
        return main
    }

    /// Development aid: what the weekly summary would say right now, from the stored week. `Launchwatch --summary`
    private static func summaryOnce() {
        Task {
            let directory = ProcessInfo.processInfo.environment["LAUNCHWATCH_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            let summary = await Watcher(store: Store(directory: directory ?? Store.defaultDirectory)).summaryNow()
            print(summary.map { $0.text(now: $0.date) } ?? "Nothing to say: no sites, or less than a day of checks.")
            exit(0)
        }
    }

    /// Development aid: one real pulse, printed. `Launchwatch --pulse example.com`
    private static func pulseOnce(_ address: String) {
        Task {
            let url = URL(string: address.contains("://") ? address : "https://\(address)/")
            guard let url else {
                print("Not an address.")
                exit(1)
            }
            let result = await URLSessionPulser().pulse(url)
            let certificate = result.certificateExpiry.map { "certificate \(Words.expiry($0, now: Date()))" } ?? "no certificate seen"
            print(result.ok ? "\(url.host ?? address) answered \(result.status) in \(Words.time(result.milliseconds)), \(certificate)"
                            : "\(url.host ?? address) is down: \(result.reason), \(certificate)")
            if let phases = result.phases {
                let parts = PhaseTimings.Phase.allCases.compactMap { phase in phases[phase].map { "\(phase.words) \(Words.time($0))" } }
                print(parts.joined(separator: ", "))
            }
            if !result.ok, let cause = Diagnosis.down(DownEvidence(site: Site(url: url.absoluteString, host: url.host ?? address, added: Date()),
                                                                   state: SiteState(), result: result, now: Date())) {
                print(cause.sentence)
            }
            exit(result.ok ? 0 : 1)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
