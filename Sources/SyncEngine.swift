import Foundation
import Darwin

struct PlannedCopy: Identifiable, Hashable {
    enum Kind: String { case added, updated }
    var id: String
    var title: String
    var from: String
    var src: URL
    var dest: URL
    var kind: Kind
    var lastActivity: Date
}

struct PlannedNote: Hashable { var src: URL; var dest: URL }

struct SyncPlan {
    var target: String
    var targetName: String
    var targetDir: URL
    var mode: SourceMode
    var copies: [PlannedCopy] = []
    var alreadyCurrent = 0
    var keptNewer: [String] = []
    var notes: [PlannedNote] = []
    var missingParents: [String] = []
    var toQuit: [Profile] = []
    var recentlyActive: [ChatRecord] = []
    var newest: ChatRecord?
    var totalAfter = 0
    var relinks = 0

    var added: Int { copies.filter { $0.kind == .added }.count }
    var updated: Int { copies.filter { $0.kind == .updated }.count }
}

struct SyncOptions {
    var quitOthers = true
    var openAfter = true
    var dryRun = false
}

enum SwitchStep: Int, CaseIterable, Comparable {
    case close, backup, copy, open
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct SyncResult {
    var plan: SyncPlan
    var backup: URL?
    var quit: QuitReport
    var opened: Bool
    var openedRunning: Bool
}

enum SyncError: LocalizedError {
    case noTarget(String)
    case io(String)
    var errorDescription: String? {
        switch self {
        case .noTarget(let n): return "\(n) isn't signed in yet, so there's nowhere to put the chats. Open it, sign in, then try again."
        case .io(let m): return m
        }
    }
}

enum SyncEngine {
    static let fm = FileManager.default

    static func plan(_ snap: Snapshot, target: String, mode: SourceMode) throws -> SyncPlan {
        guard let t = snap.profile(target) else { throw SyncError.noTarget(target) }
        guard let tDir = t.targetDir else { throw SyncError.noTarget(t.displayName) }
        var plan = SyncPlan(target: target, targetName: t.displayName, targetDir: tDir, mode: mode)

        let sources: [Profile]
        switch mode {
        case .newestEverywhere: sources = snap.profiles
        case .profile(let f): sources = snap.profiles.filter { $0.folder == f || $0.folder == target }
        }
        var best: [String: ChatRecord] = [:]
        for p in sources {
            var pool = p.chats
            if case .profile = mode, p.folder == target { pool = Array(t.ownChats.values) }
            for c in pool where best[c.id].map({ c.lastActivity > $0.lastActivity }) ?? true { best[c.id] = c }
        }
        plan.newest = best.values.max { $0.lastActivity < $1.lastActivity }

        for (sid, b) in best {
            let dest = tDir.appendingPathComponent(sid + ".json")
            if b.path.standardizedFileURL.path == dest.standardizedFileURL.path { plan.alreadyCurrent += 1; continue }
            if let mine = t.ownChats[sid] {
                if mine.lastActivity >= b.lastActivity { plan.alreadyCurrent += 1; continue }
                plan.copies.append(PlannedCopy(id: sid, title: b.title, from: b.profileFolder, src: b.path, dest: dest, kind: .updated, lastActivity: b.lastActivity))
            } else {
                plan.copies.append(PlannedCopy(id: sid, title: b.title, from: b.profileFolder, src: b.path, dest: dest, kind: .added, lastActivity: b.lastActivity))
            }
        }
        if case .profile(let f) = mode {
            for (sid, mine) in t.ownChats {
                if let theirs = snap.profile(f)?.chats.filter({ $0.id == sid }).max(by: { $0.lastActivity < $1.lastActivity }),
                   mine.lastActivity > theirs.lastActivity { plan.keptNewer.append(mine.title) }
            }
        }
        plan.copies.sort { $0.lastActivity > $1.lastActivity }

        for p in sources where p.folder != target {
            for sid in best.keys {
                let dir = p.notesDir.appendingPathComponent(sid)
                guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) else { continue }
                for case let src as URL in en {
                    guard (try? src.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let rel = String(src.path.dropFirst(p.notesDir.path.count + 1))
                    let dest = t.notesDir.appendingPathComponent(rel)
                    let sm = mtime(src), dm = fm.fileExists(atPath: dest.path) ? mtime(dest) : .distantPast
                    guard sm > dm else { continue }
                    if let i = plan.notes.firstIndex(where: { $0.dest == dest }) {
                        if sm > mtime(plan.notes[i].src) { plan.notes[i] = PlannedNote(src: src, dest: dest) }
                    } else {
                        plan.notes.append(PlannedNote(src: src, dest: dest))
                    }
                }
            }
        }

        var after = Set(t.ownChats.keys); best.keys.forEach { after.insert($0) }
        plan.totalAfter = after.count
        for sid in after {
            let rec = best[sid] ?? t.ownChats[sid]
            if let parent = rec?.parentId, !after.contains(parent) { plan.missingParents.append(rec?.title ?? sid) }
        }

        plan.relinks = Relocator.brokenLinks(t, base: t.path.deletingLastPathComponent())

        plan.toQuit = snap.runningProfiles
        let cutoff = Date().addingTimeInterval(-180)
        let runningFolders = Set(plan.toQuit.map(\.folder))
        plan.recentlyActive = snap.newest.values.filter { $0.lastActivity > cutoff && runningFolders.contains($0.profileFolder) }
            .sorted { $0.lastActivity > $1.lastActivity }
        return plan
    }

    static func run(scanner: Scanner, target: String, mode: SourceMode, options: SyncOptions,
                    progress: @escaping (SwitchStep, String) -> Void) throws -> SyncResult {
        var snap = scanner.scan()
        var report = QuitReport()
        if !options.dryRun && !scanner.isCopy {
            let toClose = options.quitOthers ? snap.runningProfiles : snap.runningProfiles.filter { $0.folder == target }
            if !toClose.isEmpty {
                progress(.close, "Closing \(toClose.map(\.displayName).joined(separator: " and "))")
                report = try QuitHelper.quit(toClose.map { QuitTarget(name: $0.displayName, pids: $0.pids) }) { progress(.close, $0) }
                Thread.sleep(forTimeInterval: 0.6)
                snap = scanner.scan()
            }
        }

        let plan = try plan(snap, target: target, mode: mode)
        if options.dryRun { return SyncResult(plan: plan, backup: nil, quit: report, opened: false, openedRunning: false) }
        guard let t = snap.profile(target) else { throw SyncError.noTarget(target) }

        progress(.backup, "Backing up \(t.displayName)'s chats")
        let label: String
        switch mode {
        case .newestEverywhere: label = "Before switching to \(t.displayName)"
        case .profile(let f): label = "Before copying chats from \(snap.profile(f)?.displayName ?? f)"
        }
        let backup = try makeBackup(t, label: label)

        progress(.copy, plan.copies.isEmpty ? "Chats are already up to date" : "Copying \(plan.copies.count) chats")
        try fm.createDirectory(at: plan.targetDir, withIntermediateDirectories: true)
        for n in plan.notes {
            try fm.createDirectory(at: n.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replace(n.dest, with: n.src)
        }
        for c in plan.copies {
            guard let text = try? String(contentsOf: c.src, encoding: .utf8) else { throw SyncError.io("Couldn't read \(c.title).") }
            try Relocator.install(recordText: text, to: c.dest, base: scanner.base, target: t, projectsDir: scanner.projectsDir)
        }
        if let fresh = scanner.scan().profile(target) {
            _ = try Relocator.repair(fresh, base: scanner.base, projectsDir: scanner.projectsDir)
        }

        var opened = false, nowRunning = false
        if options.openAfter && !scanner.isCopy {
            progress(.open, "Opening \(t.displayName)")
            open(t)
            opened = true
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.5)
                if Scanner.runningClaude()[t.folder] != nil { nowRunning = true; break }
            }
        }
        return SyncResult(plan: plan, backup: backup, quit: report, opened: opened, openedRunning: nowRunning)
    }

    static func restore(scanner: Scanner, backup: BackupInfo, openAfter: Bool, step: @escaping (String) -> Void) throws -> URL {
        var snap = scanner.scan()
        guard let p = snap.profile(backup.profileFolder) else { throw SyncError.noTarget(backup.profileFolder) }
        if p.running && !scanner.isCopy {
            step("Closing \(p.displayName)")
            _ = try QuitHelper.quit([QuitTarget(name: p.displayName, pids: p.pids)], step: step)
            snap = scanner.scan()
        }
        guard let t = snap.profile(backup.profileFolder), let dir = t.targetDir else { throw SyncError.noTarget(p.displayName) }
        step("Backing up what's there now")
        let safety = try makeBackup(t, label: "Before restoring the backup from \(backup.date.formatted(date: .abbreviated, time: .shortened))")
        step("Putting back \(backup.chatCount) chats")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix("local_") && f.hasSuffix(".json") {
            try fm.removeItem(at: dir.appendingPathComponent(f))
        }
        for f in (try? fm.contentsOfDirectory(atPath: backup.sessionsDir.path)) ?? [] where f.hasPrefix("local_") && f.hasSuffix(".json") {
            try fm.copyItem(at: backup.sessionsDir.appendingPathComponent(f), to: dir.appendingPathComponent(f))
        }
        if let notes = backup.notesDir, let en = fm.enumerator(at: notes, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let src as URL in en where (try? src.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let rel = String(src.path.dropFirst(notes.path.count + 1))
                let dest = t.notesDir.appendingPathComponent(rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try replace(dest, with: src)
            }
        }
        if openAfter && !scanner.isCopy { step("Opening \(t.displayName)"); open(t) }
        return safety
    }

    // MARK: Pieces

    static func open(_ p: Profile) {
        var args = ["-na", Scanner.claudeApp.path]
        if p.folder != "Claude" { args += ["--args", "--user-data-dir=\(p.path.path)"] }
        Scanner.shell("/usr/bin/open", args)
    }

    static func makeBackup(_ t: Profile, label: String) throws -> URL {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"; fmt.locale = Locale(identifier: "en_US_POSIX")
        var url = t.path.appendingPathComponent("sync-backup-" + fmt.string(from: Date()))
        var n = 2
        while fm.fileExists(atPath: url.path) { url = t.path.appendingPathComponent("sync-backup-\(fmt.string(from: Date()))-\(n)"); n += 1 }
        let sessions = url.appendingPathComponent("sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        if let dir = t.targetDir {
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix("local_") && f.hasSuffix(".json") {
                try fm.copyItem(at: dir.appendingPathComponent(f), to: sessions.appendingPathComponent(f))
            }
        }
        if fm.fileExists(atPath: t.notesDir.path) {
            try fm.copyItem(at: t.notesDir, to: url.appendingPathComponent("notes"))
        }
        let manifest: [String: Any] = ["label": label, "createdAt": ISO8601DateFormatter().string(from: Date()),
                                       "profile": t.folder, "targetDir": t.targetDir?.path ?? ""]
        if let d = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try? d.write(to: url.appendingPathComponent("relaycat.json"))
        }
        return url
    }

    static func replace(_ dest: URL, with src: URL) throws {
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).relaycat-tmp")
        try? fm.removeItem(at: tmp)
        do {
            try fm.copyItem(at: src, to: tmp)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw SyncError.io("Couldn't copy \(src.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func mtime(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

enum HistoryStore {
    static var url: URL {
        let dir = Scanner.settingsFolder(in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }
    static func load() -> [HistoryEntry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([HistoryEntry].self, from: d)) ?? []
    }
    static func append(_ e: HistoryEntry) {
        var all = load(); all.insert(e, at: 0)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(Array(all.prefix(500))) { try? d.write(to: url, options: .atomic) }
    }
}
