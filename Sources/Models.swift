import Foundation

struct UsageWindow: Hashable {
    var usedPct: Double
    var resetsAt: Date?
    var probablyReset: Bool = false
    var leftPct: Double { max(0, min(100, 100 - usedPct)) }
}

struct UsageInfo: Hashable {
    var fiveHour: UsageWindow?
    var week: UsageWindow?
    var fable: UsageWindow?
    var takenAt: Date?
    var source: String
    var note: String?
}

struct UsageSample: Hashable {
    var t: Date
    var fiveHour: Double?
    var week: Double?
}

struct ChatRecord: Identifiable, Hashable {
    var id: String
    var title: String
    var lastActivity: Date
    var cwd: String?
    var archived: Bool
    var parentId: String?
    var path: URL
    var profileFolder: String

    var project: String {
        guard let cwd, !cwd.isEmpty else { return "" }
        if cwd.contains("/scratch-workspaces/") { return "No folder" }
        return (cwd as NSString).lastPathComponent
    }
}

struct Profile: Identifiable, Hashable {
    var id: String { folder }
    var folder: String
    var displayName: String
    var path: URL
    var colorKey: String?
    var shortcutApp: URL?
    var appByGraft = false
    var live: LiveUsage?
    var accountUuid: String?
    var orgUuid: String?
    var email: String?
    var fullName: String?
    var plan: String?
    var pids: [Int32] = []
    var usage: UsageInfo?
    var history: [UsageSample] = []
    var chats: [ChatRecord] = []
    var targetDir: URL?
    var ownChats: [String: ChatRecord] = [:]

    var running: Bool { !pids.isEmpty }
    var notesDir: URL { path.appendingPathComponent("side-session-notes") }
    var isMain: Bool { folder == "Claude" }

    var badge: String {
        if displayName == "Claude" { return "1" }
        if let n = displayName.split(separator: " ").last, Int(n) != nil, displayName.hasPrefix("Claude") { return String(n) }
        return String(displayName.prefix(1)).uppercased()
    }

    var roomLeft: Double? {
        let vals = [usage?.fiveHour?.leftPct, usage?.week?.leftPct].compactMap { $0 }
        return vals.min()
    }
}

struct Snapshot {
    var profiles: [Profile]
    var newest: [String: ChatRecord]
    var behindCounts: [String: Int]
    var cliEmail: String?
    var cliAccount: String?
    var limitsCheckedAt: Date?
    var scannedAt: Date
    var signature: Int

    func profile(_ folder: String) -> Profile? { profiles.first { $0.folder == folder } }
    var runningProfiles: [Profile] { profiles.filter { $0.running } }
    var newestChat: ChatRecord? { newest.values.max { $0.lastActivity < $1.lastActivity } }
    func behind(_ p: Profile) -> Int { behindCounts[p.folder] ?? 0 }

    func sharesAccount(_ p: Profile) -> [Profile] {
        guard let a = p.accountUuid else { return [] }
        return profiles.filter { $0.folder != p.folder && $0.accountUuid == a }
    }

    var suggestion: Profile? {
        var seen = Set<String>()
        var pool: [Profile] = []
        for p in profiles.sorted(by: { ($0.running ? 0 : 1) < ($1.running ? 0 : 1) }) {
            guard p.roomLeft != nil, p.targetDir != nil else { continue }
            if p.plan == "API" { continue }
            let key = p.accountUuid ?? p.folder
            if seen.contains(key) { continue }
            seen.insert(key); pool.append(p)
        }
        return pool.max { a, b in
            let ra = a.roomLeft ?? 0, rb = b.roomLeft ?? 0
            if ra != rb { return ra < rb }
            return (a.usage?.week?.leftPct ?? 0) < (b.usage?.week?.leftPct ?? 0)
        }
    }

    var onBestProfile: Bool {
        guard let s = suggestion else { return true }
        return runningProfiles.contains { $0.folder == s.folder || ($0.accountUuid != nil && $0.accountUuid == s.accountUuid) }
    }
}

enum SourceMode: Hashable {
    case newestEverywhere
    case profile(String)
}

struct BackupInfo: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var profileFolder: String
    var date: Date
    var chatCount: Int
    var sessionsDir: URL
    var notesDir: URL?
    var label: String?
}

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var kind: String
    var target: String
    var source: String
    var added: Int
    var updated: Int
    var notes: Int
    var quit: [String]
    var backup: String?
    var ok: Bool
    var message: String
}
