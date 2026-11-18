import AppKit
import LaunchwatchCore
import SwiftUI

// MARK: Tokens

/// Color only ever means severity. Everything else is the text colors and a hairline.
enum Tone {
    static let critical = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    static let good = Color(nsColor: .systemGreen)
    static let hairline = Color(nsColor: .separatorColor)
    static let wash = Color.primary.opacity(0.055)
    static let lift = Color.primary.opacity(0.1)
    /// The same warm paper as Launchcheck, so the two read as one family.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.108, green: 0.105, blue: 0.101, alpha: 1)
            : NSColor(srgbRed: 0.992, green: 0.989, blue: 0.983, alpha: 1)
    })

    static func of(_ level: Level) -> Color {
        switch level {
        case .critical: return critical
        case .warning: return warning
        case .good: return good
        }
    }

    static func of(_ condition: Health.Condition) -> Color {
        switch condition {
        case .critical: return critical
        case .warning: return warning
        case .fine: return good
        case .unknown: return .secondary
        }
    }
}

/// Three sizes and no more.
enum Face {
    static let verdict = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 12.5)
    static let bodyStrong = Font.system(size: 12.5, weight: .medium)
    static let address = Font.system(size: 12.5, design: .monospaced)
    static let addressStrong = Font.system(size: 12.5, weight: .semibold, design: .monospaced)
    static let small = Font.system(size: 11)
    static let smallStrong = Font.system(size: 11, weight: .medium)
}

enum Metrics {
    static let width: CGFloat = 380
    static let gutter: CGFloat = 16
    static let row: CGFloat = 46
    static let dot: CGFloat = 8
    static let dotGap: CGFloat = 11
    /// Where text lines up under a host name.
    static let indent: CGFloat = gutter + dot + dotGap
    static let radius: CGFloat = 12
    /// Room around the panel for its shadow.
    static let margin: CGFloat = 36
    static let press: CGFloat = 0.97
}

/// The same motion scale as Launchcheck, after the tokens at transitions.dev: a few durations, one decisive curve,
/// small distances and a light blur.
enum Motion {
    static let quick = 0.15
    static let fast = 0.25

    /// Starts fast and settles gently.
    static func smoothOut(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    static let press = smoothOut(quick)
    /// A row or the settings opening; closing is quicker than opening.
    static let expand = smoothOut(fast)
    static let collapse = smoothOut(quick)
    /// A pill or a switch thumb travelling.
    static let move = smoothOut(fast)
    /// Words changing in place.
    static let swap = Animation.easeInOut(duration: quick)
}

private struct Veil: ViewModifier {
    let blur: CGFloat
    let y: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: blur).offset(y: y).opacity(opacity)
    }
}

extension AnyTransition {
    /// Content that opens in place: it sharpens as it fades in, with no movement of its own.
    static var soft: AnyTransition {
        .modifier(active: Veil(blur: 2, y: 0, opacity: 0), identity: Veil(blur: 0, y: 0, opacity: 1))
    }

    /// Text swap: the old words leave upward and the new arrive from below, through a light blur.
    static var swap: AnyTransition {
        .asymmetric(insertion: .modifier(active: Veil(blur: 2, y: 4, opacity: 0), identity: Veil(blur: 0, y: 0, opacity: 1)),
                    removal: .modifier(active: Veil(blur: 2, y: -4, opacity: 0), identity: Veil(blur: 0, y: 0, opacity: 1)))
    }
}

private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering README images, where AppKit-backed controls cannot be drawn.
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

// MARK: Small pieces

struct Hairline: View {
    var inset: CGFloat = 0

    var body: some View {
        Tone.hairline.frame(height: 1).padding(.leading, inset)
    }
}

struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// The status dot. A ring when nothing is known yet, so "no news" never reads as "good news".
struct StatusDot: View {
    let condition: Health.Condition
    var muted = false
    var size: CGFloat = Metrics.dot

    var body: some View {
        Group {
            if condition == .unknown {
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            } else {
                Circle().fill(muted ? Color.secondary.opacity(0.6) : Tone.of(condition))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The one moving thing in the app: a small arc that turns while a check is running.
struct Spinner: View {
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 10, height: 10)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !reduceMotion, !isSnapshot else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: Sparkline

/// Response time over the last day. The line breaks where nothing was measured; outages sit on the floor in red.
struct Sparkline: View {
    let buckets: [Bucket]
    var muted = false

    var body: some View {
        ZStack {
            SparkShape(buckets: buckets, part: .line)
                .stroke(Color.primary.opacity(muted ? 0.25 : 0.5), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            SparkShape(buckets: buckets, part: .outages)
                .stroke(muted ? Color.secondary : Tone.critical, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

struct SparkShape: Shape {
    enum Part { case line, outages }

    let buckets: [Bucket]
    let part: Part

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard buckets.count > 1 else { return path }
        let values = buckets.compactMap { bucket -> Int? in
            if case .up(let ms) = bucket { return ms }
            return nil
        }
        // The top of the chart is twice the usual time, so a steady site draws a calm line through the middle
        // and only a real spike reaches the top.
        let median = Stats.median(values) ?? 1
        let top = CGFloat(max(values.max() ?? 1, median * 2, 1))
        let step = rect.width / CGFloat(buckets.count - 1)
        let floor = rect.maxY - 1
        func x(_ index: Int) -> CGFloat { rect.minX + CGFloat(index) * step }
        func y(_ ms: Int) -> CGFloat { floor - (rect.height - 3) * min(1, CGFloat(ms) / top) }

        switch part {
        case .line:
            var drawing = false
            var runLength = 0
            for (index, bucket) in buckets.enumerated() {
                if case .up(let ms) = bucket {
                    let point = CGPoint(x: x(index), y: y(ms))
                    if drawing { path.addLine(to: point) } else { path.move(to: point) }
                    drawing = true
                    runLength += 1
                    // A reading with nothing either side still deserves a mark.
                    let alone = runLength == 1 && (index + 1 >= buckets.count || !buckets[index + 1].isUp)
                    if alone { path.addLine(to: CGPoint(x: point.x + 0.01, y: point.y)) }
                } else {
                    drawing = false
                    runLength = 0
                }
            }
        case .outages:
            var index = 0
            while index < buckets.count {
                guard buckets[index] == .down else {
                    index += 1
                    continue
                }
                var end = index
                while end + 1 < buckets.count, buckets[end + 1] == .down { end += 1 }
                path.move(to: CGPoint(x: x(index), y: floor))
                // Even one missed reading gets a mark wide enough to see.
                let finish = max(x(end), x(index) + 3)
                path.move(to: CGPoint(x: min(x(index), rect.maxX - 3), y: floor))
                path.addLine(to: CGPoint(x: min(finish, rect.maxX), y: floor))
                index = end + 1
            }
        }
        return path
    }
}

extension Bucket {
    var isUp: Bool {
        if case .up = self { return true }
        return false
    }
}

// MARK: Controls

/// The one button shape: a quiet outlined pill that darkens under the pointer and dips when pressed.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration)
    }

    private struct Look: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Face.smallStrong)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(configuration.isPressed ? Tone.lift : (hovering ? Tone.wash : .clear)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tone.hairline))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? Metrics.press : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A square button that holds one symbol.
struct IconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration)
    }

    private struct Look: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(configuration.isPressed ? Tone.lift : (hovering ? Tone.wash : .clear)))
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? Metrics.press : 1)
                .animation(Motion.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A full-width row that can be pressed: a flat wash under the pointer, a darker one and a slight dip when pressed.
struct RowButton: ButtonStyle {
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration, highlighted: highlighted)
    }

    private struct Look: View {
        let configuration: Configuration
        let highlighted: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .background(configuration.isPressed ? Tone.lift : (hovering || highlighted ? Tone.wash : .clear))
                .contentShape(Rectangle())
                .animation(Motion.press, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// A short list of choices side by side, in the system's shape and none of its color.
struct Segments<Value: Hashable>: View {
    let label: String
    let choices: [(value: Value, title: String)]
    let selection: Value
    let choose: (Value) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.value) { choice in
                Button { choose(choice.value) } label: { Text(choice.title) }
                    .buttonStyle(Segment(selected: choice.value == selection))
                    .accessibilityLabel("\(label), \(choice.title)")
                    .accessibilityAddTraits(choice.value == selection ? .isSelected : [])
            }
        }
        .background(alignment: .leading) {
            // One pill that slides between the choices.
            if let index = choices.firstIndex(where: { $0.value == selection }) {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Tone.surface)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Tone.hairline))
                    .frame(width: 50, height: 20)
                    .offset(x: CGFloat(index) * 52)
                    .animation(reduceMotion ? nil : Motion.move, value: index)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tone.wash))
    }

    private struct Segment: ButtonStyle {
        let selected: Bool

        func makeBody(configuration: Configuration) -> some View {
            Look(configuration: configuration, selected: selected)
        }

        struct Look: View {
            let configuration: Configuration
            let selected: Bool
            @State private var hovering = false

            var body: some View {
                configuration.label
                    .font(selected ? Face.smallStrong : Face.small)
                    .monospacedDigit()
                    .foregroundStyle(selected || hovering ? .primary : .secondary)
                    .frame(width: 50, height: 20)
                    .background {
                        if !selected, configuration.isPressed {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Tone.lift)
                        }
                    }
                    .contentShape(Rectangle())
                    .scaleEffect(configuration.isPressed ? Metrics.press : 1)
                    .animation(Motion.press, value: configuration.isPressed)
                    .onHover { hovering = $0 }
            }
        }
    }
}

/// An on/off switch drawn in the text color, so it carries no meaning it has not earned.
struct Switch: View {
    let label: String
    let isOn: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: toggle) {
            Capsule()
                .fill(isOn ? Color.primary.opacity(0.85) : Tone.lift)
                .overlay(Capsule().strokeBorder(Tone.hairline))
                .frame(width: 30, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(isOn ? Tone.surface : Color.white)
                        .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
                .animation(reduceMotion ? nil : Motion.move, value: isOn)
        }
        .buttonStyle(Dip())
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private struct Dip: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? Metrics.press : 1)
                .animation(Motion.press, value: configuration.isPressed)
        }
    }
}

extension Date {
    /// "just now", "3 min ago", "2 h ago", "12 Nov".
    func ago(from now: Date) -> String {
        let seconds = now.timeIntervalSince(self)
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400)) d ago" }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}
