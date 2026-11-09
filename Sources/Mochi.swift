import SwiftUI

// Mochi, the app's cat. Drawn with Canvas in a 100 x 100 space, emoji style: soft filled shapes,
// no black outlines, so it reads on light and dark backgrounds alike.
enum MochiMood: Hashable {
    case ready, tired, napping, happy
}

extension MochiMood {
    /// Session first: napping once the session (or the week) is used up, tired when it's low.
    static func forLimits(_ p: Profile) -> MochiMood {
        let session = p.usage?.fiveHour?.leftPct, week = p.usage?.week?.leftPct
        if let w = week, w < 1 { return .napping }
        if let s = session, s < 1 { return .napping }
        if let s = session, s < 15 { return .tired }
        return .ready
    }

    static func headline(_ p: Profile) -> String {
        switch forLimits(p) {
        case .napping: return "\(p.displayName) is napping"
        case .tired: return "\(p.displayName) is getting tired"
        default: return "\(p.displayName) is on duty"
        }
    }
}

enum MochiPalette {
    static let faceTop = Color(red: 1.00, green: 0.84, blue: 0.50)
    static let faceBottom = Color(red: 0.97, green: 0.66, blue: 0.27)
    static let rim = Color(red: 0.82, green: 0.48, blue: 0.16)
    static let stripe = Color(red: 0.90, green: 0.55, blue: 0.20)
    static let innerEar = Color(red: 0.98, green: 0.62, blue: 0.60)
    static let eye = Color(red: 0.23, green: 0.15, blue: 0.11)
    static let nose = Color(red: 0.90, green: 0.42, blue: 0.40)
    static let blush = Color(red: 1.00, green: 0.50, blue: 0.47)
    static let sweat = Color(red: 0.42, green: 0.72, blue: 1.00)
    static let sparkle = Color(red: 1.00, green: 0.80, blue: 0.24)
}

struct MochiFace: View {
    var mood: MochiMood = .ready
    var size: CGFloat = 56
    var blink: CGFloat = 1
    var earTilt: Double = 0
    var zPhase: Double = 0
    var showsExtras = true

    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 100
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * k, y: y * k, width: w * k, height: h * k) }
            let fur = GraphicsContext.Shading.linearGradient(Gradient(colors: [MochiPalette.faceTop, MochiPalette.faceBottom]),
                                                             startPoint: p(50, 18), endPoint: p(50, 86))

            func ear(_ base1: CGPoint, _ tip: CGPoint, _ base2: CGPoint, tilt: Double, pivot: CGPoint) {
                var e = Path(); e.move(to: base1)
                e.addQuadCurve(to: tip, control: CGPoint(x: (base1.x + tip.x) / 2 - 2 * k, y: (base1.y + tip.y) / 2))
                e.addQuadCurve(to: base2, control: CGPoint(x: (tip.x + base2.x) / 2 + 2 * k, y: (tip.y + base2.y) / 2))
                e.closeSubpath()
                let t = CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: tilt * .pi / 180).translatedBy(x: -pivot.x, y: -pivot.y)
                let shape = e.applying(t)
                ctx.fill(shape, with: fur)
                ctx.stroke(shape, with: .color(MochiPalette.rim.opacity(0.55)), lineWidth: 1.6 * k)
                var inner = Path(); inner.move(to: CGPoint(x: base1.x + (tip.x - base1.x) * 0.22, y: base1.y + (tip.y - base1.y) * 0.22))
                inner.addLine(to: CGPoint(x: tip.x + (base1.x + base2.x - 2 * tip.x) * 0.16, y: tip.y + (base1.y + base2.y - 2 * tip.y) * 0.18))
                inner.addLine(to: CGPoint(x: base2.x + (tip.x - base2.x) * 0.22, y: base2.y + (tip.y - base2.y) * 0.22))
                inner.closeSubpath()
                ctx.fill(inner.applying(t), with: .color(MochiPalette.innerEar))
            }
            ear(p(16, 46), p(22, 10), p(46, 26), tilt: -earTilt, pivot: p(30, 36))
            ear(p(84, 46), p(78, 10), p(54, 26), tilt: earTilt, pivot: p(70, 36))

            let head = Path(ellipseIn: r(14, 22, 72, 62))
            ctx.fill(head, with: fur)
            ctx.stroke(head, with: .color(MochiPalette.rim.opacity(0.55)), lineWidth: 1.6 * k)

            for dx in [-6.0, 0, 6] {
                var s = Path(); s.move(to: p(50 + dx, 25)); s.addLine(to: p(50 + dx * 0.8, 33))
                ctx.stroke(s, with: .color(MochiPalette.stripe.opacity(0.75)), style: StrokeStyle(lineWidth: 2.6 * k, lineCap: .round))
            }

            ctx.fill(Path(ellipseIn: r(22, 58, 13, 8)), with: .color(MochiPalette.blush.opacity(0.42)))
            ctx.fill(Path(ellipseIn: r(65, 58, 13, 8)), with: .color(MochiPalette.blush.opacity(0.42)))

            switch mood {
            case .ready:
                let h = 11 * max(0.12, blink)
                for cx in [38.0, 62.0] {
                    ctx.fill(Path(ellipseIn: r(cx - 4.6, 50 - h / 2, 9.2, h)), with: .color(MochiPalette.eye))
                    if blink > 0.6 {
                        ctx.fill(Path(ellipseIn: r(cx - 2.2, 50 - h / 2 + 1.6, 3.4, 3.4)), with: .color(.white))
                    }
                }
            case .tired:
                // Droopy half-shut eyes: the lid sags toward the outside of the face.
                let d = 6.5 * max(0.15, blink)
                for (cx, outer) in [(38.0, -1.0), (62.0, 1.0)] {
                    let a = p(cx + outer * 4.6, 51.6), b = p(cx - outer * 4.6, 49.4)
                    var eye = Path(); eye.move(to: a); eye.addLine(to: b)
                    eye.addQuadCurve(to: a, control: p(cx, 50.5 + d * 1.5)); eye.closeSubpath()
                    ctx.fill(eye, with: .color(MochiPalette.eye))
                    var lid = Path(); lid.move(to: a); lid.addLine(to: b)
                    ctx.stroke(lid, with: .color(MochiPalette.eye), style: StrokeStyle(lineWidth: 1.8 * k, lineCap: .round))
                    if blink > 0.6 {
                        ctx.fill(Path(ellipseIn: r(cx - 2.2, 51.4, 2.2, 2.2)), with: .color(.white))
                    }
                }
            case .napping:
                for cx in [38.0, 62.0] {
                    var e = Path(); e.move(to: p(cx - 5, 50)); e.addQuadCurve(to: p(cx + 5, 50), control: p(cx, 55))
                    ctx.stroke(e, with: .color(MochiPalette.eye), style: StrokeStyle(lineWidth: 2.6 * k, lineCap: .round))
                }
            case .happy:
                for cx in [38.0, 62.0] {
                    var e = Path(); e.move(to: p(cx - 5, 52)); e.addQuadCurve(to: p(cx + 5, 52), control: p(cx, 44))
                    ctx.stroke(e, with: .color(MochiPalette.eye), style: StrokeStyle(lineWidth: 2.8 * k, lineCap: .round))
                }
            }

            var nose = Path(); nose.move(to: p(46.5, 58)); nose.addLine(to: p(53.5, 58)); nose.addLine(to: p(50, 62)); nose.closeSubpath()
            ctx.fill(nose, with: .color(MochiPalette.nose))
            var mouth = Path(); mouth.move(to: p(44, 64)); mouth.addQuadCurve(to: p(50, 64), control: p(47, 68))
            mouth.addQuadCurve(to: p(56, 64), control: p(53, 68))
            ctx.stroke(mouth, with: .color(MochiPalette.eye), style: StrokeStyle(lineWidth: 1.8 * k, lineCap: .round))
            if mood == .happy {
                var open = Path(); open.move(to: p(46, 66)); open.addQuadCurve(to: p(54, 66), control: p(50, 72)); open.closeSubpath()
                ctx.fill(open, with: .color(MochiPalette.nose.opacity(0.85)))
            }

            for (y, dy) in [(60.0, -1.5), (65.0, 1.5)] {
                var wl = Path(); wl.move(to: p(30, y)); wl.addLine(to: p(19, y + dy))
                var wr = Path(); wr.move(to: p(70, y)); wr.addLine(to: p(81, y + dy))
                ctx.stroke(wl, with: .color(MochiPalette.eye.opacity(0.45)), style: StrokeStyle(lineWidth: 1.3 * k, lineCap: .round))
                ctx.stroke(wr, with: .color(MochiPalette.eye.opacity(0.45)), style: StrokeStyle(lineWidth: 1.3 * k, lineCap: .round))
            }

            guard showsExtras else { return }
            switch mood {
            case .tired:
                var d = Path(); d.move(to: p(86, 30)); d.addQuadCurve(to: p(86, 42), control: p(93, 40))
                d.addQuadCurve(to: p(86, 30), control: p(79, 40))
                ctx.fill(d, with: .color(MochiPalette.sweat))
            case .napping:
                let rise = CGFloat(zPhase) * 6
                let a = 1 - zPhase * 0.6
                ctx.draw(Text("z").font(.system(size: 14 * k, weight: .heavy, design: .rounded)).foregroundStyle(MochiPalette.sweat.opacity(a)),
                         at: p(90, 20 - rise))
                ctx.draw(Text("z").font(.system(size: 10 * k, weight: .heavy, design: .rounded)).foregroundStyle(MochiPalette.sweat.opacity(a * 0.8)),
                         at: p(98, 8 - rise))
            case .happy:
                for (cx, cy, s) in [(86.0, 22.0, 6.0), (12.0, 18.0, 4.0)] {
                    var st = Path()
                    st.move(to: p(cx, cy - s)); st.addQuadCurve(to: p(cx + s, cy), control: p(cx, cy))
                    st.addQuadCurve(to: p(cx, cy + s), control: p(cx, cy)); st.addQuadCurve(to: p(cx - s, cy), control: p(cx, cy))
                    st.addQuadCurve(to: p(cx, cy - s), control: p(cx, cy))
                    ctx.fill(st, with: .color(MochiPalette.sparkle))
                }
            case .ready: break
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(label)
    }

    var label: String {
        switch mood {
        case .ready: return "Mochi, ready"
        case .tired: return "Mochi, getting tired"
        case .napping: return "Mochi, napping"
        case .happy: return "Mochi, happy"
        }
    }
}

/// Mochi with idle life: an occasional blink, and floating z's while napping. Cheap: one slow timeline.
struct LiveMochi: View {
    var mood: MochiMood
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            MochiFace(mood: mood, size: size)
        } else {
            // Redraws only when something changes: twice per blink, or a few steps a second for the z's.
            TimelineView(MochiSchedule(napping: mood == .napping)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let blink: CGFloat = t.truncatingRemainder(dividingBy: MochiSchedule.cycle) < MochiSchedule.closed ? 0.1 : 1
                let z = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4
                MochiFace(mood: mood, size: size, blink: mood == .napping ? 1 : blink, zPhase: z)
            }
        }
    }
}

struct MochiSchedule: TimelineSchedule {
    static let cycle = 4.2, closed = 0.14, zStep = 0.4
    var napping: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start.timeIntervalSinceReferenceDate
        let napping = napping, step = mode == .lowFrequency ? 1.0 : Self.zStep
        return AnyIterator {
            let now = next
            if napping {
                next = (now / step).rounded(.down) * step + step
            } else {
                let c = (now / Self.cycle).rounded(.down) * Self.cycle
                next = now < c + Self.closed ? c + Self.closed : c + Self.cycle
            }
            return Date(timeIntervalSinceReferenceDate: now)
        }
    }
}

/// Mochi seen from the side, walking. Legs and tail move while `walking` is on.
struct MochiWalker: View {
    var walking: Bool
    var size: CGFloat = 54

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !walking)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let step = walking ? sin(t * 14) : 0
            let wag = walking ? sin(t * 6) * 10 : 4
            Canvas { ctx, sz in
                let k = sz.width / 100
                func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }
                let fur = GraphicsContext.Shading.linearGradient(Gradient(colors: [MochiPalette.faceTop, MochiPalette.faceBottom]),
                                                                 startPoint: p(50, 40), endPoint: p(50, 90))
                var tail = Path(); tail.move(to: p(18, 62))
                tail.addQuadCurve(to: p(6, 34 + CGFloat(wag) * 0.4), control: p(2, 56))
                ctx.stroke(tail, with: .color(MochiPalette.faceBottom), style: StrokeStyle(lineWidth: 7 * k, lineCap: .round))
                let legs: [(CGFloat, Double)] = [(26, step), (36, -step), (58, -step), (68, step)]
                for (x, ph) in legs {
                    let lift = CGFloat(max(0, ph)) * 4
                    var l = Path(); l.move(to: p(x, 70)); l.addLine(to: p(x + CGFloat(ph) * 2, 86 - lift))
                    ctx.stroke(l, with: .color(MochiPalette.rim), style: StrokeStyle(lineWidth: 6.5 * k, lineCap: .round))
                }
                let body = Path(roundedRect: CGRect(x: 14 * k, y: 52 * k, width: 64 * k, height: 26 * k), cornerRadius: 13 * k)
                ctx.fill(body, with: fur)
                ctx.stroke(body, with: .color(MochiPalette.rim.opacity(0.5)), lineWidth: 1.4 * k)
                for x in [36.0, 46.0] {
                    var s = Path(); s.move(to: p(x, 53)); s.addLine(to: p(x - 2, 60))
                    ctx.stroke(s, with: .color(MochiPalette.stripe.opacity(0.75)), style: StrokeStyle(lineWidth: 2.4 * k, lineCap: .round))
                }
            }
            .overlay(alignment: .topTrailing) {
                MochiFace(mood: .ready, size: size * 0.6, blink: 1, showsExtras: false)
                    .offset(x: size * 0.1, y: size * 0.05 + CGFloat(walking ? abs(step) : 0) * 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Every few minutes Mochi strolls along the bottom of the window, then sits and fades away.
/// Runs only while the window is key, honours Reduce Motion, and can be switched off.
struct MochiStroll: View {
    @AppStorage("mochiWanders") private var wanders = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var active
    @State private var x: CGFloat = -80
    @State private var visible = false
    @State private var walking = false
    @State private var facingRight = true
    @State private var width: CGFloat = 800

    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { _, w in width = w }
            if visible {
                MochiWalker(walking: walking, size: 54)
                    .scaleEffect(x: facingRight ? 1 : -1, y: 1)
                    .position(x: x, y: g.size.height - 30)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .task(id: wanders && !reduceMotion) {
            guard wanders && !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(Self.firstDelay))
            while !Task.isCancelled {
                if active == .key || Self.firstDelay < 25 { await stroll() }
                try? await Task.sleep(for: .seconds(Double.random(in: 180...360)))
            }
        }
    }

    static var firstDelay: Double {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["RELAYCAT_STROLL"], let d = Double(s) { return d }
        #endif
        return 25
    }

    @MainActor func stroll() async {
        facingRight = Bool.random()
        let from: CGFloat = facingRight ? -60 : width + 60
        let stop = width * CGFloat.random(in: 0.3...0.7)
        x = from
        withAnimation(.easeIn(duration: 0.3)) { visible = true }
        walking = true
        withAnimation(.linear(duration: 4.5)) { x = stop }
        try? await Task.sleep(for: .seconds(4.5))
        walking = false
        try? await Task.sleep(for: .seconds(2.2))
        walking = true
        let end: CGFloat = facingRight ? width + 70 : -70
        withAnimation(.linear(duration: 4.5)) { x = end }
        try? await Task.sleep(for: .seconds(4.5))
        walking = false
        withAnimation(.easeOut(duration: 0.3)) { visible = false }
    }
}

/// The app icon artwork: Mochi inside two round "switch" arrows.
struct SwapCatLogo: View {
    var size: CGFloat = 1024

    var body: some View {
        let s = size
        ZStack {
            RoundedRectangle(cornerRadius: s * 0.2237, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.19, blue: 0.24), Color(red: 0.11, green: 0.10, blue: 0.13)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.805, height: s * 0.805)
            Canvas { ctx, sz in
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let r = sz.width * 0.30
                let w = sz.width * 0.045
                let arrowColor = Color(red: 0.97, green: 0.66, blue: 0.27)
                for start in [-80.0, 100.0] {
                    var a = Path()
                    a.addArc(center: c, radius: r, startAngle: .degrees(start), endAngle: .degrees(start + 120), clockwise: false)
                    ctx.stroke(a, with: .color(arrowColor), style: StrokeStyle(lineWidth: w, lineCap: .round))
                    let end = start + 120
                    let tip = CGPoint(x: c.x + r * cos(end * .pi / 180), y: c.y + r * sin(end * .pi / 180))
                    let dir = (end + 90) * .pi / 180
                    let side = (end) * .pi / 180
                    var h = Path()
                    h.move(to: CGPoint(x: tip.x + cos(dir) * w * 1.6, y: tip.y + sin(dir) * w * 1.6))
                    h.addLine(to: CGPoint(x: tip.x + cos(side) * w * 1.25, y: tip.y + sin(side) * w * 1.25))
                    h.addLine(to: CGPoint(x: tip.x - cos(side) * w * 1.25, y: tip.y - sin(side) * w * 1.25))
                    h.closeSubpath()
                    ctx.fill(h, with: .color(arrowColor))
                }
            }
            .frame(width: s, height: s)
            MochiFace(mood: .ready, size: s * 0.46, showsExtras: false)
                .offset(y: s * 0.01)
        }
        .frame(width: s, height: s)
    }
}
