import SwiftUI
import AppKit

// MARK: Formatting

enum Fmt {
    static func ago(_ d: Date?) -> String {
        guard let d else { return "never" }
        if abs(d.timeIntervalSinceNow) < 45 { return "just now" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func agoShort(_ d: Date) -> String {
        if abs(d.timeIntervalSinceNow) < 45 { return "just now" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let t = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return "today at \(t)" }
        if cal.isDateInTomorrow(d) { return "tomorrow at \(t)" }
        if cal.isDateInYesterday(d) { return "yesterday at \(t)" }
        if abs(d.timeIntervalSinceNow) < 6 * 86400 { return d.formatted(.dateTime.weekday(.wide)) + " at \(t)" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    static func resets(_ w: UsageWindow) -> String {
        guard let r = w.resetsAt else { return "" }
        if w.probablyReset { return "Full again since \(r.formatted(date: .omitted, time: .shortened))" }
        let left = r.timeIntervalSinceNow
        if left < 3600 { return "Resets in \(max(1, Int(left / 60))) min" }
        if left < 6 * 3600 { return "Resets in \(Int(left / 3600)) h \(Int(left.truncatingRemainder(dividingBy: 3600) / 60)) min" }
        return "Resets \(when(r))"
    }

    static func plural(_ n: Int, _ word: String, _ pluralWord: String? = nil) -> String {
        "\(n) \(n == 1 ? word : (pluralWord ?? word + "s"))"
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}

// MARK: Colour

func profileColor(_ key: String?) -> Color {
    switch key {
    case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
    case "blue": return .blue
    case "green": return .green
    case "graphite": return Color(white: 0.55)
    case "research", "teal": return .teal
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "pink": return .pink
    case "purple": return .indigo
    default: return .secondary
    }
}

func levelColor(_ left: Double) -> Color {
    if left < 15 { return .red }
    if left < 40 { return .orange }
    return .green
}

// MARK: Buttons

enum DS {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let page: CGFloat = 20
    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 10
    static let sheetWidth: CGFloat = 480
    static let actionWidth: CGFloat = 84
}

extension View {
    func primaryAction() -> some View { buttonStyle(.borderedProminent) }

    func secondaryAction() -> some View { buttonStyle(.bordered) }

    func card(padding: CGFloat = DS.l) -> some View {
        self.padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
    }

    func sectionTitle() -> some View { font(.headline) }
}

struct StatusTag: View {
    let text: String
    var color: Color = .green
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }
}

struct Notice<Actions: View>: View {
    let icon: String
    var tint: Color = .accentColor
    let title: String
    let message: String
    var onClose: (() -> Void)? = nil
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: DS.m) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: DS.xs) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: DS.m) { actions }.padding(.top, DS.xs)
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Hide")
            }
        }
        .card(padding: DS.m + 2)
    }
}

struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

enum Haptic {
    static func done() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
    static func tick() { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
}

// MARK: Profile pieces

struct Avatar: View {
    let p: Profile
    var size: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(profileColor(p.colorKey).gradient)
                .overlay(
                    Text(p.badge)
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                )
                .frame(width: size, height: size)
            if p.running {
                Circle()
                    .fill(.green)
                    .frame(width: size * 0.32, height: size * 0.32)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(x: 1, y: 1)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: p.running)
        .accessibilityLabel("\(p.displayName)\(p.running ? ", open" : "")")
    }
}

struct LimitLine: View {
    let label: String
    let window: UsageWindow?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            LimitBar(window: window)
            Group {
                if let w = window {
                    Text("\(Int(w.leftPct))%")
                        .contentTransition(.numericText(value: w.leftPct))
                        .foregroundStyle(w.leftPct < 15 ? Color.red : Color.primary)
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .frame(width: 36, alignment: .trailing)
        }
        .help(window.map { "\(Int($0.leftPct))% left. \(Fmt.resets($0))" } ?? "No numbers yet")
    }
}

struct LimitBar: View {
    let window: UsageWindow?
    var height: CGFloat = 6

    var body: some View {
        let left = window?.leftPct ?? 0
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule()
                        .fill(levelColor(left).gradient)
                        .frame(width: window == nil ? 0 : max(height, g.size.width * left / 100))
                }
            }
            .frame(height: height)
            .animation(.smooth(duration: 0.6), value: left)
    }
}

struct LimitBlock: View {
    let title: String
    let window: UsageWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                if let w = window {
                    Text("\(Int(w.leftPct))% left")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: w.leftPct))
                } else {
                    Text("No numbers yet").foregroundStyle(.tertiary)
                }
            }
            LimitBar(window: window, height: 8)
            if let w = window, !Fmt.resets(w).isEmpty {
                Text(Fmt.resets(w)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct IconCircle: View {
    let systemName: String
    @State private var hover = false
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(hover ? 0.12 : 0.06), in: Circle())
            .contentShape(Circle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}

struct BigEmptyState<Actions: View>: View {
    var symbol: String? = nil
    var mood: MochiMood = .ready
    let title: String
    let message: String
    @ViewBuilder let actions: Actions
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: DS.l) {
            LiveMochi(mood: mood, size: 104)
                .offset(y: shown || reduceMotion ? 0 : 8)
            VStack(spacing: DS.s) {
                Text(title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .lineLimit(4)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: DS.m) { actions }.padding(.top, DS.xs)
        }
        .padding(DS.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduceMotion ? 1 : 0.97)
        .onAppear { withAnimation(.smooth(duration: 0.35)) { shown = true } }
    }
}
