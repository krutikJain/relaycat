import Foundation

struct ProfileMeta: Codable, Hashable {
    var name: String?
    var color: String?
    var aliases: [String] = []
}

enum ColorPreset: String, CaseIterable, Identifiable {
    case claude, blue, green, teal, orange, pink, red, yellow, purple, graphite
    var id: String { rawValue }
    var label: String { rawValue == "claude" ? "Claude" : rawValue.capitalized }
}

final class Registry {
    let url: URL
    private let fm = FileManager.default

    init(settingsDir: URL) { url = settingsDir.appendingPathComponent("profiles.json") }

    func load() -> [String: ProfileMeta] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: ProfileMeta].self, from: d)) ?? [:]
    }

    func save(_ r: [String: ProfileMeta]) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(r) { try? d.write(to: url, options: .atomic) }
    }

    func update(_ folder: String, _ change: (inout ProfileMeta) -> Void) {
        var r = load()
        var m = r[folder] ?? ProfileMeta()
        change(&m)
        r[folder] = m
        save(r)
    }

    func remove(_ folder: String) { var r = load(); r[folder] = nil; save(r) }

    func importIfNeeded(graftDir: URL, settingsDir: URL) {
        guard !fm.fileExists(atPath: url.path) else { return }
        var r: [String: ProfileMeta] = [:]
        if let d = try? Data(contentsOf: graftDir.appendingPathComponent("shortcuts.json")),
           let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
            for s in arr {
                guard let folder = s["folder"] as? String else { continue }
                r[folder] = ProfileMeta(name: s["name"] as? String, color: s["iconPreset"] as? String)
            }
        }
        if let d = try? Data(contentsOf: settingsDir.appendingPathComponent("names.json")),
           let old = try? JSONDecoder().decode([String: ProfileMeta].self, from: d) {
            for (folder, m) in old {
                var e = r[folder] ?? ProfileMeta()
                if let n = m.name { e.name = n }
                e.aliases = Array(Set(e.aliases + m.aliases))
                r[folder] = e
            }
        }
        if r["Claude"] == nil { r["Claude"] = ProfileMeta(name: "Claude", color: "claude") }
        save(r)
    }
}
