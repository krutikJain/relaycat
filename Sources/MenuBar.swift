import SwiftUI

struct MenuBarPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) var openWindow
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
                    VStack(spacing: 0) {
                        Button { tap(p) } label: { row(p, snap) }
                            .buttonStyle(PressStyle())
                            .disabled(p.targetDir == nil || m.working)
                            .onHover { hovered = $0 ? p.folder : (hovered == p.folder ? nil : hovered) }
                        if let q = m.quickSwitch, q.target == p.folder, q.phase == .confirm {
                            QuickSwitchCard(p: p, snap: snap, moreOptions: { go(p) })
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            Divider().padding(.top, 6)
            HStack {
                Button("Open Relaycat") { show() }
                Spacer()
                Button("Quit Relaycat") { AppLifecycle.quitCompletely() }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 330)
        .animation(.smooth(duration: 0.25), value: m.quickSwitch)
    }

    // MARK: Header

    @ViewBuilder var header: some View {
        if let q = m.quickSwitch, q.phase != .confirm {
            progress(q)
            Divider().padding(.horizontal, 14)
        } else if let open = m.snap?.runningProfiles.first {
            summary(open)
            Divider().padding(.horizontal, 14)
        }
    }

    func progress(_ q: AppModel.QuickSwitch) -> some View {
        let name = m.snap?.profile(q.target)?.displayName ?? q.target
        let steps = SwitchStep.allCases.count
        let done = q.phase == .done ? steps : (q.step?.rawValue ?? 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SwitchMochi(phase: q.phase == .running ? .running : q.phase == .done ? .done : .failed, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.phase == .running ? "Switching to \(name)" : q.phase == .done ? "All set" : "The switch didn't finish")
                        .font(.headline)
                    Text(q.text).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            if q.phase != .failed {
                HStack(spacing: 4) {
                    ForEach(0..<steps, id: \.self) { i in
                        Capsule()
                            .fill(i < done || (i == done && q.phase == .running) ? Color.accentColor : Color.primary.opacity(0.12))
                            .opacity(i == done && q.phase == .running ? 0.55 : 1)
                            .frame(height: 4)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button("Try again") { m.quickSwitch?.phase = .confirm }.controlSize(.small)
                    Button("Open Relaycat") { m.quickSwitch = nil; show() }.buttonStyle(.link).font(.callout)
                    Spacer()
                    Button("Dismiss") { m.quickSwitch = nil }.buttonStyle(.link).font(.callout)
                }
            }
        }
        .padding(14)
        .transition(.opacity)
    }

    func summary(_ p: Profile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LiveMochi(mood: MochiMood.forLimits(p), size: 40, lookingDown: hovered != nil)
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
            if let w, w.probablyReset || w.resetsAt != nil {
                Text(w.probablyReset ? Fmt.resets(w) : "Back to full \(Fmt.when(w.resetsAt!))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Rows

    func row(_ p: Profile, _ snap: Snapshot) -> some View {
        let expanded = m.quickSwitch?.target == p.folder && m.quickSwitch?.phase == .confirm
        return HStack(spacing: 10) {
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
        .background(expanded || hovered == p.folder ? Color.primary.opacity(expanded ? 0.09 : 0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .help(p.running ? "Bring \(p.displayName) to the front" : "Switch to \(p.displayName)")
    }

    func tap(_ p: Profile) {
        if p.running {
            m.quickSwitch = nil
            if let pid = p.pids.first { NSRunningApplication(processIdentifier: pid)?.activate() }
            return
        }
        m.toggleQuickSwitch(p.folder)
    }

    func show() {
        if AppLifecycle.openMainWindow == nil { AppLifecycle.openMainWindow = { openWindow(id: "main") } }
        AppLifecycle.showMainWindow()
    }

    // The full switch sheet, for choosing where chats come from.
    func go(_ p: Profile) {
        m.quickSwitch = nil
        show()
        m.sidebar = .page(.profiles)
        m.selected = p.folder
        m.requestSwitch(p.folder)
    }
}

/// The inline confirm step in the menu bar panel: what the switch will do, then Switch or Cancel.
struct QuickSwitchCard: View {
    @EnvironmentObject var m: AppModel
    let p: Profile
    let snap: Snapshot
    let moreOptions: () -> Void
    var plan: SyncPlan? { m.quickPlan }
    var planError: String? { m.quickPlanError }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let planError {
                Text(planError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let plan {
                VStack(alignment: .leading, spacing: 4) {
                    line("power", plan.toQuit.isEmpty ? "No Claude is open right now." : "Closes \(Fmt.list(plan.toQuit.map(\.displayName))).")
                    line("arrow.down.doc", plan.copies.isEmpty ? "Chats are already up to date." : "Brings \(Fmt.plural(plan.copies.count, "newer chat")) along, after a backup.")
                    if let warning = limitWarning {
                        line("gauge.with.dots.needle.0percent", warning, tint: .orange)
                    }
                    if let busy = plan.recentlyActive.first {
                        line("exclamationmark.triangle.fill", "“\(busy.title)” was working \(Fmt.ago(busy.lastActivity)). It stops when Claude closes.", tint: .orange)
                    }
                    if !plan.keptDiverged.isEmpty {
                        line("arrow.triangle.branch", "\(Fmt.plural(plan.keptDiverged.count, "chat")) went further in \(p.displayName), so \(plan.keptDiverged.count == 1 ? "it stays" : "they stay") as \(plan.keptDiverged.count == 1 ? "it is" : "they are").")
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 8) {
                Button("Switch") { m.startQuickSwitch() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil)
                Button("Cancel") { m.quickSwitch = nil }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("More options…", action: moreOptions).buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
    }

    // Switching to an account that's out of room is allowed, but worth saying.
    var limitWarning: String? {
        if let w = p.usage?.week, w.leftPct < 1 {
            return "\(p.displayName)'s week is used up" + (w.resetsAt.map { ", back \(Fmt.when($0))." } ?? ".")
        }
        if let s = p.usage?.fiveHour, s.leftPct < 1 {
            return "\(p.displayName)'s session is used up" + (s.resetsAt.map { ", back \(Fmt.when($0))." } ?? ".")
        }
        return nil
    }

    func line(_ icon: String, _ text: String, tint: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint).frame(width: 14)
            Text(text).font(.callout).foregroundStyle(tint == .secondary ? Color.primary : tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let st = MenuBarIcon.state(for: m.snap?.runningProfiles.first)
        Image(nsImage: MenuBarIcon.image(st))
            .accessibilityLabel(st.spoken)
            .onAppear { AppLifecycle.openMainWindow = { openWindow(id: "main") } }
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
        // Without a reset time, the window refills no later than its length after the numbers were read.
        let taken = p.usage?.takenAt
        if let w = week, w.leftPct < 1 {
            let (prog, text) = countdown(to: w.resetsAt ?? taken?.addingTimeInterval(7 * 86400), window: 7 * 86400, now: now, dayStyle: true)
            return IndicatorState(kind: .weekOut(progress: prog, text: text),
                                  spoken: "\(p.displayName): this week is used up, back \(text)")
        }
        if let s = session, s.leftPct < 1 {
            let (prog, text) = countdown(to: s.resetsAt ?? taken?.addingTimeInterval(5 * 3600), window: 5 * 3600, now: now, dayStyle: false)
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
