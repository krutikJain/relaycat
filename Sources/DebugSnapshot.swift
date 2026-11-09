#if DEBUG
import AppKit
import SwiftUI
import ScreenCaptureKit

enum DebugSnapshot {
    @MainActor static func startIfRequested(_ m: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let look = env["RELAYCAT_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua)
        }
        if env["RELAYCAT_DRAG"] != nil {
            func splits(_ v: NSView) -> [NSSplitView] { ((v as? NSSplitView).map { [$0] } ?? []) + v.subviews.flatMap(splits) }
            func drag(_ w: NSWindow, _ sv: NSSplitView, from: CGFloat, to: CGFloat) {
                let panes = sv.arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 1 }
                guard panes.count > 1 else { return }
                let first = panes[0].frame
                let local = NSPoint(x: first.maxX + sv.dividerThickness / 2, y: sv.bounds.midY)
                let start = sv.convert(local, to: nil)
                func ev(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: start.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                }
                var x = start.x
                for i in 0..<120 {
                    x = start.x + (to - from) * CGFloat(sin(Double(i) / 9)) 
                    NSApp.postEvent(ev(.leftMouseDragged, x), atStart: false)
                }
                NSApp.postEvent(ev(.leftMouseUp, x), atStart: false)
                w.sendEvent(ev(.leftMouseDown, start.x))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                MainActor.assumeIsolated {
                    guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { return }
                    for width in [1240.0, 1000.0, 940.0] {
                        w.setContentSize(NSSize(width: width, height: 720))
                        w.layoutIfNeeded()
                        for sv in splits(w.contentView!) where sv.isVertical && sv.arrangedSubviews.filter({ !$0.isHidden && $0.frame.width > 1 }).count > 1 {
                            print("drag split at width \(Int(width)), divider \(Int(sv.arrangedSubviews.filter { !$0.isHidden && $0.frame.width > 1 }[0].frame.maxX))")
                            drag(w, sv, from: 0, to: 260)
                        }
                    }
                    print("drag done")
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if env["RELAYCAT_STRESS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                var tick = 0
                Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { t in
                    MainActor.assumeIsolated {
                        tick += 1
                        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { return }
                        let phase = Double(tick) / 40
                        if tick % 2 == 0 {
                            w.setContentSize(NSSize(width: 950 + 350 * (0.5 + 0.5 * sin(phase)), height: 700))
                        }
                        func splits(_ v: NSView) -> [NSSplitView] { (v as? NSSplitView).map { [$0] } ?? [] + v.subviews.flatMap(splits) }
                        for sv in splits(w.contentView!) where sv.subviews.count > 1 {
                            let span = sv.isVertical ? sv.bounds.width : sv.bounds.height
                            sv.setPosition(span * (0.2 + 0.25 * (0.5 + 0.5 * sin(phase * 1.7))), ofDividerAt: 0)
                        }
                        if tick == 60 { m.showInspector.toggle() }
                        if tick == 400 { m.showInspector.toggle() }
                        if tick > 900 { t.invalidate(); print("stress done"); NSApp.terminate(nil) }
                    }
                }
            }
            return
        }
        if let dir = env["RELAYCAT_SIZES"] {
            let only = env["RELAYCAT_ONLY"] != nil
            var sizes: [(String, CGFloat, CGFloat, Bool, Page)] = [
                ("profiles-1280x760", 1280, 760, true, .profiles), ("profiles-1000x640-min", 1000, 640, true, .profiles),
                ("profiles-1100x700", 1100, 700, true, .profiles),
                ("profiles-780x560-noinsp", 780, 560, false, .profiles), ("profiles-900x620-noinsp", 900, 620, false, .profiles),
                ("profiles-1600x950", 1600, 950, true, .profiles), ("chats-780x560", 780, 560, false, .chats),
                ("chats-1000x700", 1000, 700, false, .chats), ("backups-780x560", 780, 560, false, .backups),
                ("activity-780x560", 780, 560, false, .activity)]
            if only { sizes = [("profiles-900x620-noinsp", 900, 620, false, .profiles)] }
            var log = ""
            func run(_ i: Int) {
                if i >= sizes.count {
                    try? log.write(toFile: dir + "/frames.txt", atomically: true, encoding: .utf8)
                    NSApp.terminate(nil); return
                }
                let (name, w, h, insp, page) = sizes[i]
                m.sidebar = .page(page)
                m.showInspector = insp
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let win = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }) else { run(i + 1); return }
                    win.setContentSize(NSSize(width: w, height: h))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        Task { @MainActor in
                            var line = "\(name): asked \(Int(w))x\(Int(h)) window \(Int(win.frame.width))x\(Int(win.frame.height)) minSize \(Int(win.minSize.width))x\(Int(win.minSize.height)) contentMin \(Int(win.contentMinSize.width))"
                            func walk(_ v: NSView, _ d: Int) {
                                let n = String(describing: type(of: v))
                                if d < 14, n.contains("NavigationSplitRepresentable") || n.contains("SystemSplitView") || n.contains("_NSSplitViewItemViewWrapper") {
                                    line += "\n   \(n.prefix(60)) \(Int(v.frame.minX)),\(Int(v.frame.minY)) \(Int(v.frame.width))x\(Int(v.frame.height))\(v.isHidden ? " hidden" : "")"
                                }
                                for c in v.subviews { walk(c, d + 1) }
                            }
                            if let root = win.contentView { walk(root, 0) }
                            log += line + "\n"
                            await capture(dir: dir, name: name)
                            run(i + 1)
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { run(0) }
            return
        }
        if let dir = env["RELAYCAT_MENUBAR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Task { @MainActor in
                    var out = ""
                    for w in NSApp.windows {
                        out += "\(type(of: w)) level=\(w.level.rawValue) visible=\(w.isVisible) frame=\(w.frame) title=\(w.title)\n"
                        if String(describing: type(of: w)).contains("StatusBar"), let v = w.contentView {
                            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                                v.cacheDisplay(in: v.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/status-item.png"))
                            }
                        }
                    }
                    let now = Date()
                    let kinds: [(String, IndicatorState.Kind)] = [
                        ("idle", .idle), ("62", .session(left: 62)), ("100", .session(left: 100)), ("12", .session(left: 12)),
                        ("recharge-early", .recharging(progress: 0.15, text: "4h 15m")),
                        ("recharge-late", .recharging(progress: 0.75, text: "1h 20m")),
                        ("weekout", .weekOut(progress: 0.4, text: "Mon"))]
                    _ = now
                    for (light, bg) in [(true, NSColor(white: 0.93, alpha: 1)), (false, NSColor(white: 0.16, alpha: 1))] {
                        let W = 900, H = 56
                        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        bg.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
                        var x: CGFloat = 12
                        for (_, k) in kinds {
                            let img = MenuBarIcon.render(k)
                            let sz = NSSize(width: img.size.width * 2, height: img.size.height * 2)
                            let target = NSRect(x: x, y: (CGFloat(H) - sz.height) / 2, width: sz.width, height: sz.height)
                            if img.isTemplate {
                                let tinted = NSImage(size: img.size, flipped: false) { r in
                                    img.draw(in: r)
                                    (light ? NSColor.black : NSColor.white).set()
                                    r.fill(using: .sourceAtop)
                                    return true
                                }
                                tinted.draw(in: target)
                            } else { img.draw(in: target) }
                            x += sz.width + 26
                        }
                        NSGraphicsContext.restoreGraphicsState()
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/states-\(light ? "light" : "dark").png"))
                    }
                    if #available(macOS 14.4, *), let content = try? await SCShareableContent.currentProcess {
                        for (n, w) in content.windows.enumerated() {
                            out += "SCK \(n): layer=\(w.windowLayer) onScreen=\(w.isOnScreen) frame=\(w.frame) title=\(w.title ?? "")\n"
                            guard w.frame.height < 60, w.frame.width > 4 else { continue }
                            let cfg = SCStreamConfiguration()
                            cfg.width = Int(w.frame.width * 4); cfg.height = Int(w.frame.height * 4)
                            if let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) {
                                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/item-\(n).png"))
                            }
                        }
                    }
                    try? out.write(toFile: dir + "/windows.txt", atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if let dir = env["RELAYCAT_ICON"] {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                                       ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
                        let r = ImageRenderer(content: SwapCatLogo(size: 1024).frame(width: 1024, height: 1024))
                        r.scale = CGFloat(px) / 1024
                        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if let dir = env["RELAYCAT_MOCHI"] {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let sheet = HStack(spacing: 28) {
                        ForEach([MochiMood.ready, .tired, .napping, .happy], id: \.self) { m in
                            VStack(spacing: 6) { MochiFace(mood: m, size: 96, zPhase: 0.3); Text("\(String(describing: m))").font(.caption) }
                        }
                        MochiWalker(walking: false, size: 96)
                        SwapCatLogo(size: 128)
                        VStack(spacing: 8) { MochiFace(mood: .ready, size: 32); MochiFace(mood: .ready, size: 20); MochiFace(mood: .ready, size: 14) }
                    }
                    .padding(24)
                    let moods = HStack(spacing: 36) {
                        ForEach([(MochiMood.ready, "Ready"), (.tired, "Getting tired"), (.napping, "Napping"), (.happy, "Happy")], id: \.1) { m, label in
                            VStack(spacing: 10) { MochiFace(mood: m, size: 96, zPhase: 0.3); Text(label).font(.callout.weight(.medium)).foregroundStyle(.secondary) }
                                .frame(width: 130)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                        let r = ImageRenderer(content: moods.environment(\.colorScheme, scheme))
                        r.scale = 2
                        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/moods-\(name).png"))
                        }
                    }
                    for (name, scheme, bg) in [("light", ColorScheme.light, Color.white), ("dark", ColorScheme.dark, Color(white: 0.12))] {
                        let r = ImageRenderer(content: sheet.background(bg).environment(\.colorScheme, scheme))
                        r.scale = 2
                        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/mochi-\(name).png"))
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
            return
        }
        if let dir = env["RELAYCAT_PEEK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task { @MainActor in
                    await capture(dir: dir, name: "peek-a")
                    var out = ""
                    func walk(_ v: NSView, _ d: Int) {
                        guard d < 40 else { return }
                        let f = v.frame
                        out += String(repeating: " ", count: d) + "\(type(of: v)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\(v.isHidden ? " HIDDEN" : "")\(v.alphaValue < 1 ? " alpha=\(v.alphaValue)" : "")\(v.layer?.opacity ?? 1 < 1 ? " lop=\(v.layer!.opacity)" : "")\n"
                        for c in v.subviews { walk(c, d + 1) }
                    }
                    for w in NSApp.windows where w.isVisible && w.frame.width > 300 {
                        out += "WINDOW \(w.frame)\n"
                        if let v = w.contentView?.superview { walk(v, 0) }
                    }
                    try? out.write(toFile: dir + "/tree.txt", atomically: true, encoding: .utf8)
                    try? await Task.sleep(for: .seconds(4))
                    await capture(dir: dir, name: "peek-b")
                    NSApp.terminate(nil)
                }
            }
            return
        }
        guard let dir = env["RELAYCAT_SNAPSHOT"] else { return }
        if env["RELAYCAT_RENDER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let snap = m.snap else { return }
                @MainActor func save<V: View>(_ v: V, _ name: String, _ w: CGFloat) {
                    let r = ImageRenderer(content: v.environmentObject(m).frame(width: w).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                    r.scale = 2
                    if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/render-\(name).png"))
                    }
                }
                save(NowHeader(snap: snap).padding(20), "header", 900)
                if let p = snap.profile(m.selected ?? "Claude") { save(InspectorView(p: p, snap: snap, scrolls: false), "inspector", 330) }
                if let p = snap.profiles.dropFirst().first { save(ProfileRow(p: p, snap: snap).padding(10), "row", 820) }
                save(MenuBarPanel(), "menu", 330)
                save(VStack { ForEach(snap.profiles) { p in HStack { Avatar(p: p, size: 20); Text(p.displayName); Spacer(); Text("\(Int(p.usage?.week?.leftPct ?? 0))%") } } }.padding(), "sidebar-rows", 220)
                NSApp.terminate(nil)
            }
            return
        }
        var steps: [(String, () -> Void)] = Page.allCases.map { p in (p.rawValue, { m.sidebar = .page(p) }) }
        steps.append(("no-inspector", { m.sidebar = .page(.profiles); m.showInspector = false }))
        steps.append(("inspector", { m.showInspector = true }))
        if let s = env["RELAYCAT_SHEET"] { steps.append(("switch", { m.requestSwitch(s) })) }
        if let d = env["RELAYCAT_DELETE"] { steps.append(("delete", { m.request = nil; m.deleting = ProfileRef(folder: d) })) }
        if let r = env["RELAYCAT_RENAME"] { steps.append(("rename", { m.deleting = nil; m.renaming = ProfileRef(folder: r) })) }
        steps.append(("new-profile", { m.renaming = nil; m.creating = true }))
        steps.append(("take-over", { m.creating = false; m.takingOver = true }))
        steps.append(("settings", { m.takingOver = false; NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }))
        func run(_ i: Int) {
            if i >= steps.count { NSApp.terminate(nil); return }
            steps[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                Task { @MainActor in
                    await capture(dir: dir, name: "\(i)-\(steps[i].0)")
                    run(i + 1)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { run(0) }
    }

    @MainActor static func capture(dir: String, name: String) async {
        if ProcessInfo.processInfo.environment["RELAYCAT_ROWS"] != nil {
            var out = "\(name):"
            func walk(_ v: NSView) { if let t = v as? NSTableView { out += " \(type(of: t)) rows=\(t.numberOfRows) h=\(Int(t.frame.height)) hidden=\(t.isHiddenOrHasHiddenAncestor) alpha=\(t.alphaValue)" }; if v.frame.height > 800 { out += "\n   BIG \(type(of: v)) \(Int(v.frame.minX)),\(Int(v.frame.minY)) \(Int(v.frame.width))x\(Int(v.frame.height))" }; v.subviews.forEach(walk) }
            for w in NSApp.windows where w.isVisible { if let c = w.contentView { walk(c) } }
            let u = URL(fileURLWithPath: dir + "/rows.txt")
            let prev = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            try? (prev + out + "\n").write(to: u, atomically: true, encoding: .utf8)
        }
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(300))
        guard #available(macOS 14.4, *), let content = try? await SCShareableContent.currentProcess else { return }
        for (n, w) in content.windows.enumerated() where w.isOnScreen && w.frame.width > 300 && w.frame.height > 200 {
            let filter: SCContentFilter
            filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * 2); cfg.height = Int(w.frame.height * 2)
            cfg.showsCursor = false
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(n).png"))
        }
    }
}
#else
import SwiftUI

enum DebugSnapshot {
    @MainActor static func startIfRequested(_ m: AppModel) {}
}
#endif
