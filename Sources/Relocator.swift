import Foundation

// Chat records hold absolute paths into the profile that created them (scratch workspaces for
// "No folder" chats, side-session notes). When a chat moves between profiles those paths are
// rewritten to the target and the folders are copied, so deleting the old profile can't break it.
// Only those two per-chat folders are ever moved; any other path is left as it is.
enum Relocator {
    static let fm = FileManager.default

    struct Result {
        var text: String
        var moves: [(old: String, new: String)]
        var changed: Bool { !moves.isEmpty }
    }

    static func foreignProfiles(in text: String, base: URL, target: String) -> Set<String> {
        let prefix = NSRegularExpression.escapedPattern(for: base.path + "/")
        guard let re = try? NSRegularExpression(pattern: prefix + "(Claude(?:-[0-9]+)?)/(?:scratch-workspaces|side-session-notes)/") else { return [] }
        let ns = text as NSString
        var out = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let f = ns.substring(with: m.range(at: 1))
            if f != target { out.insert(f) }
        }
        return out
    }

    static func rewrite(_ text: String, base: URL, target: Profile) -> Result {
        let basePath = base.path + "/"
        let prefix = NSRegularExpression.escapedPattern(for: basePath)
        let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        let pattern = prefix + "(Claude(?:-[0-9]+)?)/(?:(scratch-workspaces/)(\(uuid))/(\(uuid))/|(side-session-notes/))([^\"\\\\\\u0000-\\u001f]*)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return Result(text: text, moves: []) }
        let ns = text as NSString
        var out = ""
        var last = 0
        var moves: [(String, String)] = []
        var seen = Set<String>()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let folder = ns.substring(with: m.range(at: 1))
            guard folder != target.folder else { continue }
            let rest = ns.substring(with: m.range(at: 6))
            if rest.contains("..") { continue }
            var newPath = basePath + target.folder + "/"
            if m.range(at: 2).location != NSNotFound {
                let acc = target.accountUuid ?? ns.substring(with: m.range(at: 3))
                let org = target.orgUuid ?? ns.substring(with: m.range(at: 4))
                newPath += "scratch-workspaces/\(acc)/\(org)/"
            } else {
                newPath += "side-session-notes/"
            }
            newPath += rest
            let oldPath = ns.substring(with: m.range)
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + newPath
            last = m.range.location + m.range.length
            if !seen.contains(oldPath) { seen.insert(oldPath); moves.append((oldPath, newPath)) }
        }
        guard !moves.isEmpty else { return Result(text: text, moves: []) }
        out += ns.substring(from: last)
        return Result(text: out, moves: moves)
    }

    @discardableResult
    static func carry(_ moves: [(old: String, new: String)], workingFolders: [(old: String, new: String)], projectsDir: URL) -> Int {
        var copied = 0
        let roots = moves.filter { m in !moves.contains { o in o.old != m.old && m.old.hasPrefix(o.old.hasSuffix("/") ? o.old : o.old + "/") } }
        for m in roots where fm.fileExists(atPath: m.old) {
            copied += merge(URL(fileURLWithPath: m.old), into: URL(fileURLWithPath: m.new))
        }
        for w in workingFolders {
            if !fm.fileExists(atPath: w.new) { try? fm.createDirectory(atPath: w.new, withIntermediateDirectories: true) }
            let from = projectsDir.appendingPathComponent(encode(w.old))
            if fm.fileExists(atPath: from.path) {
                copied += merge(from, into: projectsDir.appendingPathComponent(encode(w.new)))
            }
        }
        return copied
    }

    static func encode(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func merge(_ src: URL, into dest: URL) -> Int {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { return 0 }
        if !fm.fileExists(atPath: dest.path) {
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            return (try? fm.copyItem(at: src, to: dest)) != nil ? 1 : 0
        }
        guard isDir.boolValue else {
            if SyncEngine.mtime(src) > SyncEngine.mtime(dest) { try? SyncEngine.replace(dest, with: src); return 1 }
            return 0
        }
        var n = 0
        guard let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return 0 }
        for case let f as URL in en where (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = String(f.path.dropFirst(src.path.count + 1))
            let d = dest.appendingPathComponent(rel)
            if !fm.fileExists(atPath: d.path) || SyncEngine.mtime(f) > SyncEngine.mtime(d) {
                try? fm.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? SyncEngine.replace(d, with: f)) != nil { n += 1 }
            }
        }
        return n
    }

    @discardableResult
    static func install(recordText: String, to dest: URL, base: URL, target: Profile, projectsDir: URL) throws -> Bool {
        let r = rewrite(recordText, base: base, target: target)
        var working: [(String, String)] = []
        if r.changed,
           let old = try? JSONSerialization.jsonObject(with: Data(recordText.utf8)) as? [String: Any],
           let new = try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any] {
            for key in ["cwd", "originCwd"] {
                if let o = old[key] as? String, let n = new[key] as? String, o != n, !working.contains(where: { $0.0 == o }) {
                    working.append((o, n))
                }
            }
            carry(r.moves, workingFolders: working, projectsDir: projectsDir)
        }
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).relaycat-tmp")
        try? fm.removeItem(at: tmp)
        try Data(r.text.utf8).write(to: tmp)
        if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: tmp) }
        else { try fm.moveItem(at: tmp, to: dest) }
        return r.changed
    }

    static func repair(_ p: Profile, base: URL, projectsDir: URL, only: Set<String>? = nil) throws -> Int {
        var fixed = 0
        for c in p.ownChats.values {
            guard let text = try? String(contentsOf: c.path, encoding: .utf8) else { continue }
            let foreign = foreignProfiles(in: text, base: base, target: p.folder)
            guard !foreign.isEmpty, only.map({ !$0.isDisjoint(with: foreign) }) ?? true else { continue }
            if try install(recordText: text, to: c.path, base: base, target: p, projectsDir: projectsDir) { fixed += 1 }
        }
        return fixed
    }

    static func brokenLinks(_ p: Profile, base: URL, only: String? = nil) -> Int {
        p.ownChats.values.filter { c in
            guard let text = try? String(contentsOf: c.path, encoding: .utf8) else { return false }
            let f = foreignProfiles(in: text, base: base, target: p.folder)
            return only.map { f.contains($0) } ?? !f.isEmpty
        }.count
    }
}
