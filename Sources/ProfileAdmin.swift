import Foundation
import Darwin

enum ProfileAdmin {
    static let fm = FileManager.default

    enum AdminError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    // MARK: What a delete would lose

    struct DeleteImpact {
        var onlyHere: [ChatRecord] = []
        var newestHere: [ChatRecord] = []
        var filesInside: [ChatRecord] = []
        var linkedFrom: [(profile: Profile, chats: Int)] = []
        var trashItems: [URL] = []
    }

    static func impact(of p: Profile, in snap: Snapshot) -> DeleteImpact {
        var i = DeleteImpact()
        var latestElsewhere: [String: Date] = [:]
        for o in snap.profiles where o.folder != p.folder {
            for c in o.chats { latestElsewhere[c.id] = max(latestElsewhere[c.id] ?? .distantPast, c.lastActivity) }
        }
        var mine: [String: ChatRecord] = [:]
        for c in p.chats where mine[c.id].map({ c.lastActivity > $0.lastActivity }) ?? true { mine[c.id] = c }
        for c in mine.values {
            if let e = latestElsewhere[c.id] {
                if c.lastActivity > e { i.newestHere.append(c) }
            } else { i.onlyHere.append(c) }
        }
        let prefix = p.path.path + "/"
        i.filesInside = snap.newest.values.filter { ($0.cwd ?? "").hasPrefix(prefix) && fm.fileExists(atPath: $0.cwd!) }
        i.onlyHere.sort { $0.lastActivity > $1.lastActivity }
        i.newestHere.sort { $0.lastActivity > $1.lastActivity }
        i.filesInside.sort { $0.lastActivity > $1.lastActivity }
        i.trashItems = [p.path] + (p.shortcutApp.map { [$0] } ?? [])
        let base = p.path.deletingLastPathComponent()
        for o in snap.profiles where o.folder != p.folder {
            let n = Relocator.brokenLinks(o, base: base, only: p.folder)
            if n > 0 { i.linkedFrom.append((o, n)) }
        }
        return i
    }

    static func sizeOnDisk(_ url: URL) -> Int64 {
        let out = Scanner.shell("/usr/bin/du", ["-sk", url.path])
        return (Int64(out.split(separator: "\t").first ?? "") ?? 0) * 1024
    }

    // MARK: Repair

    @discardableResult
    static func repairAll(scanner: Scanner, step: (String) -> Void) throws -> [String: Int] {
        let snap = scanner.scan()
        let affected = snap.profiles.filter { $0.targetDir != nil && Relocator.brokenLinks($0, base: scanner.base) > 0 }
        guard !affected.isEmpty else { return [:] }
        let openOnes = affected.filter { $0.running }
        if !openOnes.isEmpty && !scanner.isCopy {
            step("Closing \(Fmt.list(openOnes.map(\.displayName))) for a moment")
            _ = try QuitHelper.quit(openOnes.map { QuitTarget(name: $0.displayName, pids: $0.pids) }, step: step)
        }
        defer { if !scanner.isCopy { for o in openOnes { step("Reopening \(o.displayName)"); SyncEngine.open(o) } } }
        var fixed: [String: Int] = [:]
        for o in affected {
            step("Fixing \(o.displayName)'s chats")
            if let fresh = scanner.scan().profile(o.folder) {
                fixed[o.folder] = try Relocator.repair(fresh, base: scanner.base, projectsDir: scanner.projectsDir)
            }
        }
        return fixed
    }

    // MARK: Delete

    // Everything goes to the Trash, never deleted outright. Files other profiles' chats still use
    // are copied out first, with those profiles closed so Claude can't write over the fix.
    static func delete(_ p: Profile, scanner: Scanner, step: (String) -> Void) throws -> [URL] {
        guard !p.isMain else {
            throw AdminError.message("This is Claude's main profile, the one Claude.app opens on its own, so it can't be deleted here.")
        }
        let parent = p.path.deletingLastPathComponent().standardizedFileURL.path
        guard parent == scanner.base.standardizedFileURL.path, p.path.lastPathComponent.hasPrefix("Claude-") else {
            throw AdminError.message("\(p.path.path) isn't a Claude profile folder, so it was left alone.")
        }
        if !scanner.isCopy, let live = Scanner.runningClaude()[p.folder] {
            step("Closing \(p.displayName)")
            _ = try QuitHelper.quit([QuitTarget(name: p.displayName, pids: live)], step: step)
        }
        let snap = scanner.scan()
        let affected = snap.profiles.filter { $0.folder != p.folder && Relocator.brokenLinks($0, base: scanner.base, only: p.folder) > 0 }
        var reopen: [Profile] = []
        let openOnes = affected.filter { $0.running }
        if !openOnes.isEmpty && !scanner.isCopy {
            step("Closing \(Fmt.list(openOnes.map(\.displayName))) for a moment")
            _ = try QuitHelper.quit(openOnes.map { QuitTarget(name: $0.displayName, pids: $0.pids) }, step: step)
            reopen = openOnes
        }
        for o in affected {
            step("Moving \(o.displayName)'s linked files out of \(p.displayName)")
            if let fresh = scanner.scan().profile(o.folder) {
                _ = try Relocator.repair(fresh, base: scanner.base, projectsDir: scanner.projectsDir, only: [p.folder])
            }
        }
        defer { for o in reopen { step("Reopening \(o.displayName)"); SyncEngine.open(o) } }

        var trashed: [URL] = []
        stopGraft(scanner, step: step)
        step("Moving \(p.folder) to the Trash")
        trashed.append(try trash(p.path))
        if let app = p.shortcutApp, fm.fileExists(atPath: app.path) {
            step("Moving \(app.lastPathComponent) to the Trash")
            trashed.append(try trash(app))
        }
        forgetInGraft(scanner) { list in list.filter { ($0["folder"] as? String) != p.folder } }
        scanner.registry.remove(p.folder)
        return trashed
    }

    static func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        do { try fm.trashItem(at: url, resultingItemURL: &result) }
        catch { throw AdminError.message("Couldn't move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)") }
        return (result as URL?) ?? url
    }

    // MARK: Name and colour

    static func validate(_ raw: String, for p: Profile?, in snap: Snapshot, scanner: Scanner) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give it a name." }
        if name.count > 40 { return "That's a bit long. Keep it under 40 characters." }
        if name.contains("/") || name.contains(":") || name.hasPrefix(".") { return "Names can't contain / or : or start with a dot." }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return "Names can't contain line breaks or tabs." }
        if name.caseInsensitiveCompare("Claude") == .orderedSame, p?.isMain != true { return "Claude is the name of the app itself. Pick another." }
        if let p, name == p.displayName { return nil }
        if snap.profiles.contains(where: { $0.folder != p?.folder && $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) {
            return "Another profile is already called \(name)."
        }
        let dest = scanner.appsDir.appendingPathComponent(name + ".app")
        if fm.fileExists(atPath: dest.path), dest.path.lowercased() != p?.shortcutApp?.path.lowercased() {
            let isOurs = ShortcutMaker.config(in: dest.appendingPathComponent("Contents/Resources")) != nil
                || fm.fileExists(atPath: dest.appendingPathComponent("Contents/Resources/graft.json").path)
            if !isOurs || p == nil { return "There's already an app called \(name) in Applications." }
        }
        return nil
    }

    static func edit(_ p: Profile, name raw: String, color: String?, makeApp: Bool, scanner: Scanner, step: (String) -> Void) throws {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        scanner.registry.update(p.folder) { m in
            if name != p.displayName, !m.aliases.contains(p.displayName) { m.aliases.append(p.displayName) }
            m.name = name
            m.color = color
        }
        guard makeApp || p.shortcutApp != nil else { return }
        stopGraft(scanner, step: step)
        step(p.shortcutApp == nil ? "Adding \(name) to Applications" : "Updating \(name) in Applications")
        try ShortcutMaker.make(name: name, folder: p.folder, profileDir: p.path, color: color, badge: badge(for: name, folder: p.folder),
                               appsDir: scanner.appsDir, replacing: p.shortcutApp, sign: !scanner.isCopy)
        forgetInGraft(scanner) { list in list.filter { ($0["folder"] as? String) != p.folder } }
    }

    static func badge(for name: String, folder: String) -> String {
        if folder == "Claude" { return "1" }
        if let n = folder.split(separator: "-").last, Int(n) != nil { return String(n) }
        return String(name.prefix(1)).uppercased()
    }

    // MARK: New profile

    static func nextFolder(scanner: Scanner) -> String {
        var n = 2
        while fm.fileExists(atPath: scanner.base.appendingPathComponent("Claude-\(n)").path) { n += 1 }
        return "Claude-\(n)"
    }

    static func create(name raw: String, color: String?, makeApp: Bool, copyServers: Bool, open: Bool,
                       scanner: Scanner, step: (String) -> Void) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = nextFolder(scanner: scanner)
        let dir = scanner.base.appendingPathComponent(folder)
        step("Creating \(folder)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if copyServers {
            let src = scanner.base.appendingPathComponent("Claude/claude_desktop_config.json")
            if fm.fileExists(atPath: src.path) {
                step("Copying MCP servers from Claude")
                try? fm.copyItem(at: src, to: dir.appendingPathComponent("claude_desktop_config.json"))
            }
        }
        scanner.registry.update(folder) { m in m.name = name; m.color = color }
        if makeApp {
            step("Adding \(name) to Applications")
            try ShortcutMaker.make(name: name, folder: folder, profileDir: dir, color: color, badge: badge(for: name, folder: folder),
                                   appsDir: scanner.appsDir, sign: !scanner.isCopy)
        }
        if open && !scanner.isCopy {
            step("Opening \(name) so you can sign in")
            var args = ["-n", "-a", Scanner.claudeApp.path, "--args", "--user-data-dir=\(dir.path)"]
            if folder == "Claude" { args = ["-n", "-a", Scanner.claudeApp.path] }
            Scanner.shell("/usr/bin/open", args)
        }
        return folder
    }

    // MARK: Moving off Claude Graft

    @discardableResult
    static func takeOverFromGraft(scanner: Scanner, step: (String) -> Void) throws -> [String] {
        let snap = scanner.scan()
        stopGraft(scanner, step: step)
        var done: [String] = []
        for p in snap.profiles where p.appByGraft {
            step("Rebuilding \(p.displayName)")
            try ShortcutMaker.make(name: p.displayName, folder: p.folder, profileDir: p.path, color: p.colorKey,
                                   badge: badge(for: p.displayName, folder: p.folder), appsDir: scanner.appsDir,
                                   replacing: p.shortcutApp, sign: !scanner.isCopy)
            done.append(p.displayName)
        }
        UserDefaults.standard.set(true, forKey: "leftGraft")
        return done
    }

    static var graftInstalled: Bool { fm.fileExists(atPath: "/Applications/Claude Graft.app") }

    static func graftPids() -> [Int32] {
        Scanner.shell("/usr/bin/pgrep", ["-f", "Claude Graft.app/Contents/MacOS/"]).split(separator: "\n").compactMap { Int32($0) }
    }

    static func stopGraft(_ scanner: Scanner, step: (String) -> Void) {
        guard !scanner.isCopy else { return }
        let pids = graftPids()
        guard !pids.isEmpty else { return }
        step("Closing Claude Graft")
        _ = try? QuitHelper.quit([QuitTarget(name: "Claude Graft", pids: pids)], step: { _ in })
    }

    static func forgetInGraft(_ scanner: Scanner, _ change: ([[String: Any]]) -> [[String: Any]]) {
        let url = scanner.graftDir.appendingPathComponent("shortcuts.json")
        guard let data = try? Data(contentsOf: url),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        try? fm.createDirectory(at: scanner.settingsDir, withIntermediateDirectories: true)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        try? data.write(to: scanner.settingsDir.appendingPathComponent("graft-shortcuts-\(fmt.string(from: Date())).json"))
        if let out = try? JSONSerialization.data(withJSONObject: change(list), options: []) { try? out.write(to: url, options: .atomic) }
    }
}
