import AppKit
import CoreImage

// Profile apps in /Applications. Each one's executable is a copy of Relaycat; when it finds
// relaycat-launch.json in its own bundle it only opens (or brings forward) that profile and exits.
// It never replaces an app that isn't a profile app.
enum ShortcutMaker {
    static let fm = FileManager.default
    static let configName = "relaycat-launch.json"
    static let legacyConfigName = "switchyard-launch.json"

    static func config(in resources: URL) -> URL? {
        [configName, legacyConfigName].map { resources.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
    }

    struct LaunchConfig: Codable { var profileDir: String }

    // MARK: Launcher mode

    static func runIfLauncher() -> Bool {
        guard let cfg = config(in: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")),
              let d = try? Data(contentsOf: cfg), let c = try? JSONDecoder().decode(LaunchConfig.self, from: d) else { return false }
        let folder = (c.profileDir as NSString).lastPathComponent
        try? fm.createDirectory(atPath: c.profileDir, withIntermediateDirectories: true)
        if let pid = Scanner.runningClaude()[folder]?.first, let app = NSRunningApplication(processIdentifier: pid) {
            app.unhide()
            app.activate(options: [.activateAllWindows])
        } else {
            var args = ["-n", "-a", Scanner.claudeApp.path]
            if folder != "Claude" { args += ["--args", "--user-data-dir=\(c.profileDir)"] }
            Scanner.shell("/usr/bin/open", args)
        }
        return true
    }

    // MARK: Building

    static func isLauncher(_ app: URL) -> Bool {
        let res = app.appendingPathComponent("Contents/Resources")
        return config(in: res) != nil
            || fm.fileExists(atPath: res.appendingPathComponent("graft.json").path)
    }

    static func bundleID(_ folder: String) -> String {
        (Bundle.main.bundleIdentifier ?? "app.relaycat.mac") + ".profile." + folder.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    @discardableResult
    static func make(name: String, folder: String, profileDir: URL, color: String?, badge: String,
                     appsDir: URL, replacing old: URL? = nil, sign: Bool = true) throws -> URL {
        let dest = appsDir.appendingPathComponent(name + ".app")
        if name.caseInsensitiveCompare("Claude") == .orderedSame || (fm.fileExists(atPath: dest.path) && !isLauncher(dest)) {
            throw ProfileAdmin.AdminError.message("There's already an app called \(name) in Applications, and it isn't a profile app, so it was left alone.")
        }
        let stage = appsDir.appendingPathComponent(".relaycat-\(UUID().uuidString).noindex")
        let contents = stage.appendingPathComponent("\(name).app/Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        let exe = contents.appendingPathComponent("MacOS/launcher")
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(), to: exe)
        let cfg = try JSONEncoder().encode(LaunchConfig(profileDir: profileDir.path))
        try cfg.write(to: contents.appendingPathComponent("Resources/\(configName)"))
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleName</key><string>\(esc(name))</string>
          <key>CFBundleDisplayName</key><string>\(esc(name))</string>
          <key>CFBundleIdentifier</key><string>\(bundleID(folder))</string>
          <key>CFBundleExecutable</key><string>launcher</string>
          <key>CFBundleIconFile</key><string>icon</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>1.0</string>
          <key>CFBundleVersion</key><string>1</string>
          <key>LSUIElement</key><true/>
          <key>LSMinimumSystemVersion</key><string>15.0</string>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try writeIcon(color: color, badge: badge, to: contents.appendingPathComponent("Resources/icon.icns"))

        let staged = stage.appendingPathComponent("\(name).app")
        if sign { Scanner.shell("/usr/bin/codesign", ["--force", "--sign", "-", staged.path]) }
        if let old, old.path != dest.path, fm.fileExists(atPath: old.path) { _ = try? fm.trashItem(at: old, resultingItemURL: nil) }
        if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: staged) }
        else { try fm.moveItem(at: staged, to: dest) }
        Scanner.shell("/usr/bin/touch", [dest.path])
        Scanner.shell("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", dest.path])
        return dest
    }

    // MARK: Icon

    static func renderBitmap(color: String?, badge: String, px: Int = 1024) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let size = CGFloat(px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }

        let base = NSWorkspace.shared.icon(forFile: Scanner.claudeApp.path)
        var rect = NSRect(x: 0, y: 0, width: size, height: size)
        if let cg = base.cgImage(forProposedRect: &rect, context: gc, hints: nil) {
            var ci = CIImage(cgImage: cg)
            let preset = color ?? "claude"
            if preset == "graphite" {
                ci = ci.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            } else if preset != "claude", let target = hue(of: preset) {
                ci = ci.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: (target - 15) * .pi / 180])
            }
            if let out = CIContext().createCGImage(ci, from: ci.extent) {
                gc.cgContext.draw(out, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
        }
        let d = size * 0.34
        let r = NSRect(x: size - d - size * 0.08, y: size * 0.08, width: d, height: d)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: r.offsetBy(dx: 0, dy: -size * 0.012)).fill()
        nsColor(color).setFill()
        NSBezierPath(ovalIn: r).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: r.insetBy(dx: size * 0.012, dy: size * 0.012)); ring.lineWidth = size * 0.02; ring.stroke()
        let font = NSFont.systemFont(ofSize: d * 0.5, weight: .bold)
        let s = NSAttributedString(string: badge, attributes: [.font: font, .foregroundColor: NSColor.white])
        let ts = s.size()
        s.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
        return rep
    }

    static func renderIcon(color: String?, badge: String, size: CGFloat = 1024) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        if let rep = renderBitmap(color: color, badge: badge, px: Int(size)) { img.addRepresentation(rep) }
        return img
    }

    static func writeIcon(color: String?, badge: String, to url: URL) throws {
        let set = url.deletingLastPathComponent().appendingPathComponent("icon.iconset")
        try? fm.removeItem(at: set)
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: set) }
        for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                           ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
            guard let rep = renderBitmap(color: color, badge: badge, px: px),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: set.appendingPathComponent("icon_\(name).png"))
        }
        Scanner.shell("/usr/bin/iconutil", ["-c", "icns", set.path, "-o", url.path])
    }

    static func hue(of preset: String) -> CGFloat? {
        switch preset {
        case "blue": return 215
        case "green": return 135
        case "teal", "research": return 180
        case "orange": return 30
        case "pink": return 330
        case "red": return 0
        case "yellow": return 52
        case "purple": return 265
        default: return nil
        }
    }

    static func nsColor(_ preset: String?) -> NSColor {
        switch preset {
        case "blue": return .systemBlue
        case "green": return .systemGreen
        case "teal", "research": return .systemTeal
        case "orange": return .systemOrange
        case "pink": return .systemPink
        case "red": return .systemRed
        case "yellow": return .systemYellow
        case "purple": return .systemIndigo
        case "graphite": return .systemGray
        default: return NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        }
    }
}
