import Foundation

enum Demo {
    static var mode: String? {
        if let m = ProcessInfo.processInfo.environment["RELAYCAT_DEMO"], !m.isEmpty { return m }
        return CommandLine.arguments.contains("--demo") ? "full" : nil
    }

    static var claudeMissing: Bool { mode == "noclaude" }

    static func snapshot() -> Snapshot {
        let now = Date()
        let root = URL(fileURLWithPath: "/tmp/relaycat-demo")
        func chat(_ id: Int, _ title: String, _ project: String, _ ago: TimeInterval, _ folder: String, parent: Int? = nil) -> ChatRecord {
            ChatRecord(id: "local_demo\(id)", title: title, lastActivity: now.addingTimeInterval(-ago), cwd: "/Users/you/Projects/\(project)",
                       archived: false, parentId: parent.map { "local_demo\($0)" },
                       path: root.appendingPathComponent("\(folder)/local_demo\(id).json"), profileFolder: folder)
        }
        let titles: [(String, String, TimeInterval)] = [
            ("Refactor the checkout flow", "storefront", 240), ("Fix flaky login test", "storefront", 3600 * 2),
            ("Draft launch announcement", "marketing-site", 3600 * 5), ("Add dark mode to settings", "ios-app", 3600 * 9),
            ("Speed up image uploads", "api", 3600 * 26), ("Write onboarding emails", "marketing-site", 3600 * 50),
            ("Migrate to the new router", "web", 3600 * 75), ("Investigate memory spike", "api", 3600 * 120),
            ("Plan Q3 roadmap", "notes", 3600 * 170), ("Add CSV export", "web", 3600 * 240),
        ]
        func window(_ left: Double, _ reset: TimeInterval) -> UsageWindow {
            UsageWindow(usedPct: 100 - left, resetsAt: now.addingTimeInterval(reset))
        }
        func history(_ base: Double) -> [UsageSample] {
            // A working week: steady weekly growth, and 5-hour use that rises during the day and resets overnight.
            var week = base
            return (0..<42).map { i in
                let t = now.addingTimeInterval(-Double(42 - i) * 4 * 3600)
                let hour = Calendar.current.component(.hour, from: t)
                let working = (9...20).contains(hour)
                if working { week = min(99, week + 1.6) }
                let five = working ? Double(20 + (hour - 9) * 6) : 0
                return UsageSample(t: t, fiveHour: five, week: week)
            }
        }
        func profile(_ folder: String, _ name: String, _ color: String, _ email: String, _ full: String, _ plan: String,
                     running: Bool, five: UsageWindow?, week: UsageWindow?, chatCount: Int, stale: Int, hist: Double) -> Profile {
            var p = Profile(folder: folder, displayName: name, path: root.appendingPathComponent(folder))
            p.colorKey = color; p.email = email; p.fullName = full; p.plan = plan
            p.accountUuid = "00000000-0000-0000-0000-" + String(format: "%012d", abs(folder.hashValue % 1_000_000_000))
            p.pids = running ? [1] : []
            p.usage = UsageInfo(fiveHour: five, week: week, fable: nil, takenAt: now.addingTimeInterval(-90), source: "Anthropic", note: nil)
            p.history = history(hist)
            p.targetDir = p.path.appendingPathComponent("claude-code-sessions/demo/demo")
            for (i, t) in titles.prefix(chatCount).enumerated() {
                var c = chat(i, t.0, t.1, t.2 + (i < stale ? 4000 : 0), folder, parent: i == 3 ? 2 : nil)
                if i < stale { c.lastActivity = now.addingTimeInterval(-t.2 - 86400) }
                p.chats.append(c); p.ownChats[c.id] = c
            }
            if folder != "Claude" { p.shortcutApp = URL(fileURLWithPath: "/Applications/\(name).app") }
            return p
        }

        var profiles: [Profile] = []
        switch mode {
        case "none", "noclaude": break
        case "single":
            profiles = [profile("Claude", "Claude", "claude", "you@example.com", "Alex Morgan", "Max 5x", running: true,
                                five: window(64, 3600 * 3), week: window(81, 86400 * 4), chatCount: 10, stale: 0, hist: 10)]
        default:
            profiles = [
                profile("Claude", "Work", "claude", "alex@work.example", "Alex Morgan", "Max 5x", running: true,
                        five: window(64, 3600 * 3 + 600), week: window(81, 86400 * 4), chatCount: 10, stale: 0, hist: 12),
                profile("Claude-2", "Personal", "blue", "alex@example.com", "Alex Morgan", "Pro", running: false,
                        five: window(0, 4800), week: window(42, 86400 * 2), chatCount: 8, stale: 2, hist: 40),
                profile("Claude-3", "Side project", "green", "build@example.com", "Alex Morgan", "Pro", running: false,
                        five: window(100, 3600 * 5), week: window(100, 86400 * 6), chatCount: 10, stale: 1, hist: 0),
                profile("Claude-4", "Team", "teal", "alex@team.example", "Alex Morgan", "Team", running: false,
                        five: window(12, 2400), week: window(63, 86400 * 3), chatCount: 6, stale: 0, hist: 30),
            ]
        }
        var newest: [String: ChatRecord] = [:]
        for p in profiles {
            for c in p.chats where newest[c.id].map({ c.lastActivity > $0.lastActivity }) ?? true { newest[c.id] = c }
        }
        var behind: [String: Int] = [:]
        for p in profiles {
            behind[p.folder] = newest.values.filter { c in !(p.ownChats[c.id].map { $0.lastActivity >= c.lastActivity } ?? false) }.count
        }
        return Snapshot(profiles: profiles, newest: newest, behindCounts: behind, cliEmail: nil, cliAccount: nil,
                        limitsCheckedAt: profiles.isEmpty ? nil : now.addingTimeInterval(-90), scannedAt: now,
                        signature: Int(now.timeIntervalSince1970 / 60) + profiles.count)
    }

    static func backups(_ snap: Snapshot) -> [String: [BackupInfo]] {
        var out: [String: [BackupInfo]] = [:]
        guard mode == "full" || mode == nil else { return out }
        for (i, p) in snap.profiles.enumerated() where i < 3 {
            out[p.folder] = (0..<(3 - i)).map { k in
                BackupInfo(url: p.path.appendingPathComponent("sync-backup-\(k)"), profileFolder: p.folder,
                           date: Date().addingTimeInterval(-Double(k + 1) * 86400 * 1.5 - Double(i) * 7200),
                           chatCount: 10 - k, sessionsDir: p.path, notesDir: nil, label: "Before switching to \(p.displayName)")
            }
        }
        return out
    }

    static func history() -> [HistoryEntry] {
        guard mode == "full" else { return [] }
        let now = Date()
        return [
            HistoryEntry(date: now.addingTimeInterval(-600), kind: "switch", target: "Work", source: "wherever newest", added: 2, updated: 3, notes: 4, quit: ["Personal"], backup: nil, ok: true, message: ""),
            HistoryEntry(date: now.addingTimeInterval(-3600 * 3), kind: "create", target: "Team", source: "Claude-4", added: 0, updated: 0, notes: 0, quit: [], backup: nil, ok: true, message: ""),
            HistoryEntry(date: now.addingTimeInterval(-3600 * 26), kind: "rename", target: "Side project", source: "Claude 3", added: 0, updated: 0, notes: 0, quit: [], backup: nil, ok: true, message: ""),
            HistoryEntry(date: now.addingTimeInterval(-3600 * 30), kind: "switch", target: "Personal", source: "wherever newest", added: 5, updated: 1, notes: 2, quit: ["Work"], backup: nil, ok: true, message: ""),
        ]
    }
}
