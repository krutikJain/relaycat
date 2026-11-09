import Foundation

struct AccountHit { var uuid: String; var email: String; var name: String?; var mtime: Date }
struct OrgHit { var uuid: String; var plan: String; var mtime: Date }

// Reads profiles, accounts, limits and chats from disk. It never writes Claude's data.
final class Scanner {
    let base: URL
    let home: URL
    let isCopy: Bool
    let appsDir: URL
    let settingsDir: URL
    private let fm = FileManager.default
    private let lock = NSLock()
    private var blobCache: [String: (Date, [AccountHit], [OrgHit])] = [:]
    private var chatCache: [String: (Date, ChatRecord?)] = [:]

    init(base: URL? = nil) {
        home = fm.homeDirectoryForCurrentUser
        self.base = base ?? home.appendingPathComponent("Library/Application Support")
        isCopy = base != nil
        appsDir = base.map { $0.appendingPathComponent("Applications") } ?? URL(fileURLWithPath: "/Applications")
        settingsDir = Scanner.settingsFolder(in: self.base)
        projectsDir = base.map { $0.appendingPathComponent("claude-projects") } ?? home.appendingPathComponent(".claude/projects")
    }

    let projectsDir: URL

    // Relaycat used to be called Switchyard. Move its settings, history and backups list over once.
    static func settingsFolder(in base: URL) -> URL {
        let dir = base.appendingPathComponent("Relaycat"), old = base.appendingPathComponent("Switchyard")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dir) }
        return dir
    }

    struct ProfileApp: Hashable { var url: URL; var byGraft: Bool }

    func profileApps() -> [String: ProfileApp] {
        var out: [String: ProfileApp] = [:]
        for n in (try? fm.contentsOfDirectory(atPath: appsDir.path)) ?? [] where n.hasSuffix(".app") && !n.hasPrefix(".") {
            let app = appsDir.appendingPathComponent(n)
            let res = app.appendingPathComponent("Contents/Resources")
            var dir: String?, graft = false
            if let cfg = ShortcutMaker.config(in: res), let d = readJSON(cfg) as? [String: Any] { dir = d["profileDir"] as? String }
            else if let d = readJSON(res.appendingPathComponent("graft.json")) as? [String: Any] { dir = d["profileDir"] as? String; graft = true }
            guard let dir else { continue }
            let folder = (dir as NSString).lastPathComponent
            guard (dir as NSString).deletingLastPathComponent == base.path || isCopy else { continue }
            if let existing = out[folder], !existing.byGraft { continue }
            out[folder] = ProfileApp(url: app, byGraft: graft)
        }
        return out
    }

    var registry: Registry { Registry(settingsDir: settingsDir) }

    var graftDir: URL { base.appendingPathComponent("ClaudeGraft") }

    static let claudeApp: URL = {
        for p in ["/Applications/Claude.app", NSHomeDirectory() + "/Applications/Claude.app"]
        where FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: "/Applications/Claude.app")
    }()

    // MARK: Profiles

    func profileFolders(apps: [String: ProfileApp] = [:], known: Set<String> = []) -> [String] {
        let names = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
        let re = try! NSRegularExpression(pattern: "^Claude(-[A-Za-z0-9][A-Za-z0-9-]*)?$")
        return names.filter { n in
            re.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil &&
            (fm.fileExists(atPath: base.appendingPathComponent(n).appendingPathComponent("config.json").path) || apps[n] != nil || known.contains(n))
        }.sorted { num($0) < num($1) }
    }

    private func num(_ folder: String) -> Int {
        if folder == "Claude" { return 1 }
        return Int(folder.split(separator: "-").last ?? "") ?? 99
    }

    func scan() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let reg = registry
        reg.importIfNeeded(graftDir: graftDir, settingsDir: settingsDir)
        let meta = reg.load()
        UsageService.importFromGraftIfNeeded(graftDir: graftDir, settingsDir: settingsDir,
                                             names: meta.compactMapValues { $0.name })
        let apps = profileApps()
        let live = UsageService.load(settingsDir)
        let procs = Scanner.runningClaude()
        var profiles: [Profile] = []

        for folder in profileFolders(apps: apps, known: Set(meta.keys)) {
            let path = base.appendingPathComponent(folder)
            guard fm.fileExists(atPath: path.path) else { continue }
            let m = meta[folder]
            let display = m?.name ?? apps[folder]?.url.deletingPathExtension().lastPathComponent
                ?? (folder == "Claude" ? "Claude" : folder.replacingOccurrences(of: "-", with: " "))
            var p = Profile(folder: folder, displayName: display, path: path)
            p.colorKey = m?.color ?? (folder == "Claude" ? "claude" : nil)
            p.shortcutApp = apps[folder]?.url
            p.appByGraft = apps[folder]?.byGraft ?? false
            let config = readJSON(path.appendingPathComponent("config.json")) as? [String: Any]
            p.accountUuid = config?["lastKnownAccountUuid"] as? String

            p.history = readHistory(path, into: &p)
            let hits = scanBlobs(path, orgs: p.orgUuid.map { [$0] } ?? [])
            if let acc = p.accountUuid, let hit = hits.0.filter({ $0.uuid == acc }).max(by: { $0.mtime < $1.mtime }) {
                p.email = hit.email; p.fullName = hit.name
            }
            if let org = p.orgUuid, let o = hits.1.filter({ $0.uuid == org }).max(by: { $0.mtime < $1.mtime }) {
                p.plan = o.plan
            }
            p.pids = procs[folder] ?? []
            p.chats = readChats(path, folder: folder)
            p.targetDir = targetDir(for: p)
            if let t = p.targetDir {
                let tp = t.standardizedFileURL.path
                for c in p.chats where c.path.deletingLastPathComponent().standardizedFileURL.path == tp {
                    p.ownChats[c.id] = c
                }
            }
            p.live = live[folder]
            p.usage = mergeUsage(live: live[folder], history: p.history)
            if p.plan == nil, let lp = live[folder]?.plan { p.plan = lp }
            profiles.append(p)
        }

        func rank(_ c: ChatRecord) -> Int {
            guard let p = profiles.first(where: { $0.folder == c.profileFolder }) else { return 0 }
            return (p.ownChats[c.id]?.path == c.path ? 2 : 0) + (p.running ? 1 : 0)
        }
        var newest: [String: ChatRecord] = [:]
        for p in profiles {
            for c in p.chats {
                guard let cur = newest[c.id] else { newest[c.id] = c; continue }
                if c.lastActivity > cur.lastActivity || (c.lastActivity == cur.lastActivity && rank(c) > rank(cur)) {
                    newest[c.id] = c
                }
            }
        }
        var behind: [String: Int] = [:]
        for p in profiles {
            behind[p.folder] = newest.values.reduce(0) { n, c in
                if let mine = p.ownChats[c.id], mine.lastActivity >= c.lastActivity { return n }
                return n + 1
            }
        }

        let cli = readJSON(home.appendingPathComponent(".claude.json")) as? [String: Any]
        let oauth = cli?["oauthAccount"] as? [String: Any]

        var h = Hasher()
        for p in profiles {
            h.combine(p.folder); h.combine(p.displayName); h.combine(p.email); h.combine(p.plan)
            h.combine(p.pids); h.combine(p.usage); h.combine(p.ownChats.count); h.combine(behind[p.folder])
            h.combine(p.history.count); h.combine(p.shortcutApp)
        }
        for c in newest.values { h.combine(c.id); h.combine(c.lastActivity); h.combine(c.title); h.combine(c.profileFolder) }
        h.combine(live.values.compactMap(\.fetchedAt).max())
        h.combine(Int(Date().timeIntervalSince1970 / 60))

        return Snapshot(profiles: profiles, newest: newest, behindCounts: behind,
                        cliEmail: oauth?["emailAddress"] as? String,
                        cliAccount: oauth?["accountUuid"] as? String,
                        limitsCheckedAt: live.values.compactMap(\.fetchedAt).max(), scannedAt: Date(), signature: h.finalize())
    }

    // MARK: Chats

    func readChats(_ path: URL, folder: String) -> [ChatRecord] {
        let root = path.appendingPathComponent("claude-code-sessions")
        var out: [ChatRecord] = []
        for acc in visibleDirs(root) {
            for org in visibleDirs(acc) {
                let files = (try? fm.contentsOfDirectory(atPath: org.path)) ?? []
                for f in files where f.hasPrefix("local_") && f.hasSuffix(".json") {
                    if let c = readChat(org.appendingPathComponent(f), folder: folder) { out.append(c) }
                }
            }
        }
        return out
    }

    func readChat(_ url: URL, folder: String) -> ChatRecord? {
        let mtime = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let c = chatCache[url.path], c.0 == mtime { return c.1 }
        var rec: ChatRecord?
        if let d = readJSON(url) as? [String: Any], let sid = d["sessionId"] as? String {
            let ms = (d["lastActivityAt"] as? NSNumber)?.doubleValue ?? (d["createdAt"] as? NSNumber)?.doubleValue ?? 0
            let spawned = (d["spawnedFrom"] as? [String: Any])?["sessionId"] as? String
            rec = ChatRecord(id: sid, title: (d["title"] as? String) ?? "Untitled",
                             lastActivity: Date(timeIntervalSince1970: ms / 1000),
                             cwd: (d["originCwd"] as? String) ?? (d["cwd"] as? String),
                             archived: (d["isArchived"] as? Bool) ?? false,
                             parentId: (d["forkedFromSessionId"] as? String) ?? spawned,
                             path: url, profileFolder: folder)
        }
        chatCache[url.path] = (mtime, rec)
        return rec
    }

    func visibleDirs(_ url: URL) -> [URL] {
        let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { url.appendingPathComponent($0) }.filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    func targetDir(for p: Profile) -> URL? {
        guard let acc = p.accountUuid else { return nil }
        let accDir = p.path.appendingPathComponent("claude-code-sessions").appendingPathComponent(acc)
        if let org = p.orgUuid { return accDir.appendingPathComponent(org) }
        let orgs = visibleDirs(accDir)
        return orgs.max { a, b in
            ((try? fm.contentsOfDirectory(atPath: a.path).count) ?? 0) < ((try? fm.contentsOfDirectory(atPath: b.path).count) ?? 0)
        }
    }

    // MARK: Usage

    func readHistory(_ path: URL, into p: inout Profile) -> [UsageSample] {
        guard let d = readJSON(path.appendingPathComponent("plan-usage-history.json")) as? [String: Any],
              let samples = d["samples"] as? [[String: Any]] else { return [] }
        if let lastOrg = samples.last?["org"] as? String { p.orgUuid = lastOrg }
        let org = p.orgUuid
        return samples.compactMap { s in
            guard let t = (s["t"] as? NSNumber)?.doubleValue else { return nil }
            if let org, let so = s["org"] as? String, so != org { return nil }
            let u = s["u"] as? [String: Any]
            return UsageSample(t: Date(timeIntervalSince1970: t / 1000),
                               fiveHour: (u?["fh"] as? NSNumber)?.doubleValue,
                               week: (u?["sd"] as? NSNumber)?.doubleValue)
        }
    }

    func mergeUsage(live: LiveUsage?, history: [UsageSample]) -> UsageInfo? {
        let now = Date()
        func window(_ used: Double?, _ reset: Date?) -> UsageWindow? {
            guard let u = used else { return nil }
            var w = UsageWindow(usedPct: u, resetsAt: reset)
            if let r = reset, r < now { w.probablyReset = true; w.usedPct = 0 }
            return w
        }
        var info: UsageInfo?
        if let l = live, let at = l.fetchedAt {
            info = UsageInfo(fiveHour: window(l.fiveHour, l.fiveHourReset), week: window(l.week, l.weekReset),
                             fable: window(l.fable, l.fableReset), takenAt: at, source: "Anthropic", note: nil)
        }
        if let last = history.last, last.t > (info?.takenAt ?? .distantPast).addingTimeInterval(60) {
            var i = info ?? UsageInfo(source: "the Claude app")
            if let fh = last.fiveHour {
                let reset = i.fiveHour?.resetsAt.flatMap { $0 > last.t ? $0 : nil }
                i.fiveHour = UsageWindow(usedPct: fh, resetsAt: reset)
                if let r = reset, r < now { i.fiveHour?.probablyReset = true; i.fiveHour?.usedPct = 0 }
            }
            if let sd = last.week {
                let reset = i.week?.resetsAt.flatMap { $0 > last.t ? $0 : nil }
                i.week = UsageWindow(usedPct: sd, resetsAt: reset)
                if let r = reset, r < now { i.week?.probablyReset = true; i.week?.usedPct = 0 }
            }
            if now.timeIntervalSince(last.t) > 7 * 86400, i.week?.resetsAt == nil { i.week?.probablyReset = true; i.week?.usedPct = 0 }
            if now.timeIntervalSince(last.t) > 5 * 3600, i.fiveHour?.resetsAt == nil { i.fiveHour?.probablyReset = true; i.fiveHour?.usedPct = 0 }
            i.takenAt = last.t; i.source = "the Claude app"
            info = i
        }
        if let p = live?.problem, info != nil { info?.note = p }
        return info
    }

    // MARK: Accounts from IndexedDB

    func scanBlobs(_ path: URL, orgs: [String]) -> ([AccountHit], [OrgHit]) {
        let root = path.appendingPathComponent("IndexedDB/https_claude.ai_0.indexeddb.blob")
        var accounts: [AccountHit] = [], orgHits: [OrgHit] = []
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return ([], []) }
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let mtime = vals?.contentModificationDate ?? .distantPast
            let key = url.path + "|" + orgs.joined(separator: ",")
            if let c = blobCache[key], c.0 == mtime {
                accounts += c.1; orgHits += c.2; continue
            }
            var a: [AccountHit] = [], o: [OrgHit] = []
            if let raw = try? Data(contentsOf: url) {
                var bytes = [UInt8](raw)
                if bytes.count > 3, bytes[0] == 0xFF, bytes[1] == 0x11, bytes[2] == 0x02,
                   let d = Snappy.decompress(Array(bytes[3...])) { bytes = d }
                a = Scanner.accounts(in: bytes, mtime: mtime)
                if !a.isEmpty || !orgs.isEmpty { o = Scanner.orgPlans(in: bytes, orgs: orgs, mtime: mtime) }
            }
            blobCache[key] = (mtime, a, o)
            accounts += a; orgHits += o
        }
        return (accounts, orgHits)
    }

    static func accounts(in d: [UInt8], mtime: Date) -> [AccountHit] {
        let needle: [UInt8] = [0x22, 0x0D] + Array("email_address".utf8)
        var out: [AccountHit] = []
        var from = 0
        while let p = Bytes.find(needle, in: d, from: from) {
            from = p + needle.count
            guard p >= 38, d[p - 37] == 0x24, d[p - 38] == 0x22,
                  let uuid = String(bytes: d[(p - 36)..<p], encoding: .ascii) else { continue }
            var q = p + needle.count
            guard let email = Bytes.v8String(d, &q), email.contains("@") else { continue }
            var name: String?
            if let f = Bytes.find(Array("full_name".utf8), in: d, from: q, to: q + 40) {
                var r = f + 9
                name = Bytes.v8String(d, &r)
            }
            out.append(AccountHit(uuid: uuid, email: email, name: name, mtime: mtime))
        }
        return out
    }

    static func orgPlans(in d: [UInt8], orgs: [String], mtime: Date) -> [OrgHit] {
        var out: [OrgHit] = []
        let tierKey = Array("rate_limit_tier".utf8)
        for org in orgs {
            let needle = Array(org.utf8)
            var from = 0
            while let p = Bytes.find(needle, in: d, from: from) {
                from = p + needle.count
                guard let t = Bytes.find(tierKey, in: d, from: from, to: from + 5000) else { continue }
                if let next = Bytes.find(Array("uuid\"$".utf8), in: d, from: from, to: t), next < t,
                   Bytes.find(Array("capabilities".utf8), in: d, from: from, to: next) == nil { continue }
                var q = t + tierKey.count
                let tier = Bytes.v8String(d, &q) ?? ""
                let window = Array(d[from..<t])
                func has(_ s: String) -> Bool { Bytes.find(Array(s.utf8), in: window) != nil }
                let plan: String
                if tier.contains("max_20x") { plan = "Max 20x" }
                else if tier.contains("max_5x") { plan = "Max 5x" }
                else if has("claude_max") { plan = "Max" }
                else if has("claude_pro") { plan = "Pro" }
                else if has("raven") { plan = has("enterprise") ? "Enterprise" : "Team" }
                else if has("api_individual") || has("\"\u{3}api") { plan = "API" }
                else { plan = "Free" }
                out.append(OrgHit(uuid: org, plan: plan, mtime: mtime))
                break
            }
        }
        return out
    }

    // MARK: Backups

    func backups(for p: Profile) -> [BackupInfo] {
        let names = (try? fm.contentsOfDirectory(atPath: p.path.path)) ?? []
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"; fmt.locale = Locale(identifier: "en_US_POSIX")
        var out: [BackupInfo] = []
        for n in names where n.contains("sync-backup-") {
            let url = p.path.appendingPathComponent(n)
            let stamp = n.components(separatedBy: "sync-backup-").last.map { String($0.prefix(15)) } ?? ""
            let attrsDate = (try? fm.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? .distantPast
            let date = fmt.date(from: stamp) ?? attrsDate
            var sessions = url.appendingPathComponent("sessions")
            if !fm.fileExists(atPath: sessions.path) { sessions = url }
            let count = ((try? fm.contentsOfDirectory(atPath: sessions.path)) ?? []).filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.count
            let notes = url.appendingPathComponent("notes")
            let manifest = (readJSON(url.appendingPathComponent("relaycat.json")) ?? readJSON(url.appendingPathComponent("switchyard.json"))) as? [String: Any]
            out.append(BackupInfo(url: url, profileFolder: p.folder, date: date, chatCount: count,
                                  sessionsDir: sessions,
                                  notesDir: fm.fileExists(atPath: notes.path) ? notes : nil,
                                  label: manifest?["label"] as? String))
        }
        return out.sorted { $0.date > $1.date }
    }

    // MARK: Helpers

    func readJSON(_ url: URL) -> Any? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }

    static func iso(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func runningClaude() -> [String: [Int32]] {
        let exe = claudeApp.appendingPathComponent("Contents/MacOS/Claude").path
        let out = shell("/bin/ps", ["-axo", "pid=,command="])
        var map: [String: [Int32]] = [:]
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { continue }
            let cmd = String(t[t.index(after: sp)...])
            guard cmd == exe || cmd.hasPrefix(exe + " ") else { continue }
            var folder = "Claude"
            if let r = cmd.range(of: "--user-data-dir=") {
                var dir = String(cmd[r.upperBound...])
                if let next = dir.range(of: " --") { dir = String(dir[..<next.lowerBound]) }
                dir = dir.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                folder = (dir as NSString).lastPathComponent
            }
            map[folder, default: []].append(pid)
        }
        return map
    }

    @discardableResult
    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
