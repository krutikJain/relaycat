import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) var openWindow
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let open = m.snap?.runningProfiles.first {
                summary(open)
                Divider().padding(.horizontal, 14)
            }
            Text("Switch to")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            if let snap = m.snap, snap.profiles.isEmpty {
                Text(m.claudeInstalled ? "Open Claude once and sign in. Your profile shows up here." : "Install Claude for Mac to get started.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let snap = m.snap {
                ForEach(snap.profiles) { p in
                    Button { go(p) } label: { row(p, snap) }
                        .buttonStyle(PressStyle())
                        .disabled(p.targetDir == nil)
                        .onHover { hovered = $0 ? p.folder : (hovered == p.folder ? nil : hovered) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            Divider().padding(.top, 6)
            HStack {
                Button("Open Relaycat") { show() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 330)
    }

    func summary(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LiveMochi(mood: MochiMood.forLimits(p), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MochiMood.headline(p)).font(.headline)
                    Text(p.email ?? p.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            limitRow("Session", p.usage?.fiveHour)
            limitRow("This week", p.usage?.week)
        }
        .padding(14)
    }

    func limitRow(_ title: String, _ w: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                if let w {
                    Text(w.leftPct < 1 ? "Used up" : "\(Int(w.leftPct))% left")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(w.leftPct < 15 ? Color.red : Color.primary)
                } else {
                    Text("No numbers yet").font(.callout).foregroundStyle(.tertiary)
                }
            }
            LimitBar(window: w, height: 5)
            if let w, let r = w.resetsAt {
                Text(w.probablyReset ? "Full again since \(r.formatted(date: .omitted, time: .shortened))"
                                     : "Back to full \(Fmt.when(r))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func row(_ p: Profile, _ snap: Snapshot) -> some View {
        HStack(spacing: 10) {
            Avatar(p: p, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(p.displayName).font(.body.weight(.medium))
                    if snap.suggestion?.folder == p.folder && !snap.onBestProfile {
                        Text("Most left").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                }
                Text(p.email ?? "Not signed in").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            let st = MenuBarIcon.state(for: p.usage == nil ? nil : p)
            Image(nsImage: MenuBarIcon.image(st))
                .foregroundStyle(.primary)
                .help(st.spoken)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hovered == p.folder ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .help(p.running ? "\(p.displayName) is open" : "Switch to \(p.displayName)")
    }

    func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    func go(_ p: Profile) {
        show()
        m.sidebar = .page(.profiles)
        m.selected = p.folder
        m.requestSwitch(p.folder)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        let st = MenuBarIcon.state(for: m.snap?.runningProfiles.first)
        Image(nsImage: MenuBarIcon.image(st))
            .accessibilityLabel(st.spoken)
    }
}

struct IndicatorState: Hashable {
    enum Kind: Hashable {
        case idle
        case session(left: Double)
        case recharging(progress: Double, text: String)
        case weekOut(progress: Double, text: String)
    }
    var kind: Kind
    var spoken: String
}

enum MenuBarIcon {
    private static var cache: [IndicatorState.Kind: NSImage] = [:]

    static func state(for p: Profile?, now: Date = Date()) -> IndicatorState {
        guard let p else { return IndicatorState(kind: .idle, spoken: "No Claude open") }
        let session = p.usage?.fiveHour, week = p.usage?.week
        if let w = week, w.leftPct < 1 {
            let (prog, text) = countdown(to: w.resetsAt, window: 7 * 86400, now: now, dayStyle: true)
            return IndicatorState(kind: .weekOut(progress: prog, text: text),
                                  spoken: "\(p.displayName): this week is used up, back \(text)")
        }
        if let s = session, s.leftPct < 1 {
            let (prog, text) = countdown(to: s.resetsAt, window: 5 * 3600, now: now, dayStyle: false)
            return IndicatorState(kind: .recharging(progress: prog, text: text),
                                  spoken: "\(p.displayName): session used up, back in \(text)")
        }
        if let left = (session ?? week)?.leftPct {
            return IndicatorState(kind: .session(left: left.rounded()),
                                  spoken: "\(p.displayName): \(Int(left)) percent of the session left")
        }
        return IndicatorState(kind: .idle, spoken: "\(p.displayName) is open, no limits yet")
    }

    static func countdown(to reset: Date?, window: TimeInterval, now: Date, dayStyle: Bool) -> (Double, String) {
        guard let reset else { return (0, "used up") }
        guard reset > now else { return (1, "now") }
        let left = reset.timeIntervalSince(now)
        let progress = max(0, min(1, 1 - left / window))
        if left >= 86400 && dayStyle { return (progress, reset.formatted(.dateTime.weekday(.abbreviated))) }
        let h = Int(left) / 3600, m = (Int(left) % 3600) / 60
        if h == 0 { return (progress, "\(max(1, m))m") }
        return (progress, m == 0 ? "\(h)h" : "\(h)h \(m)m")
    }

    static func image(_ st: IndicatorState) -> NSImage {
        if let c = cache[st.kind] { return c }
        if cache.count > 200 { cache.removeAll() }
        let img = render(st.kind)
        cache[st.kind] = img
        return img
    }

    static func render(_ kind: IndicatorState.Kind) -> NSImage {
        let heights: [CGFloat] = [4, 7, 10, 13]
        let barW: CGFloat = 3, step: CGFloat = 4.3, barsW: CGFloat = 16
        var text = "", red = false, template = true
        var textAlpha: CGFloat = 1
        switch kind {
        case .idle: break
        case .session(let left):
            text = "\(Int(left))%"
            if left < 15 { red = true; template = false }
        case .recharging(_, let t): text = t; textAlpha = 0.7
        case .weekOut(_, let t): text = t; red = true; template = false
        }
        let ink: NSColor = red ? .systemRed : .black
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink.withAlphaComponent(textAlpha)])
        let tw = text.isEmpty ? 0 : ceil(attr.size().width) + 4
        let size = NSSize(width: barsW + tw, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let base: CGFloat = 2
            for i in 0..<4 {
                let r = NSRect(x: CGFloat(i) * step, y: base, width: barW, height: heights[i])
                switch kind {
                case .idle:
                    ink.withAlphaComponent(0.3).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
                case .session(let left):
                    let on = Int(ceil(left / 25))
                    ink.withAlphaComponent(i < on ? 1 : 0.25).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
                case .recharging(let p, _), .weekOut(let p, _):
                    let o = NSBezierPath(roundedRect: r.insetBy(dx: 0.45, dy: 0.45), xRadius: 0.9, yRadius: 0.9)
                    o.lineWidth = 0.9
                    ink.withAlphaComponent(0.6).setStroke(); o.stroke()
                    let fh = max(0, heights[i] * CGFloat(p))
                    if fh > 0.5 {
                        ink.withAlphaComponent(0.45).setFill()
                        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: barW, height: fh), xRadius: 1, yRadius: 1).fill()
                    }
                }
            }
            if !text.isEmpty {
                let ts = attr.size()
                attr.draw(at: NSPoint(x: barsW + 4, y: (18 - ts.height) / 2))
            }
            return true
        }
        img.isTemplate = template
        return img
    }
}
