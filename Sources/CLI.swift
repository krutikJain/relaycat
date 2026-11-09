import Foundation

enum CLI {
    static func handle(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--ax-report"), i + 1 < args.count {
            try? "trusted=\(QuitHelper.hasAccess) pid=\(getpid()) path=\(Bundle.main.bundlePath)".write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            return true
        }
        let verbs = ["--make-app", "--usage", "--create", "--take-over", "--status", "--plan", "--sync", "--rename", "--delete", "--impact", "--ax", "--links", "--repair", "--repair-all", "--live-fix"]
        guard args.contains(where: verbs.contains) else { return false }
        func val(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        let base = val("--base").map { URL(fileURLWithPath: $0) }
        let scanner = Scanner(base: base)
        let t0 = Date()
        let snap = scanner.scan()
        if base != nil, let f = val("--make-app"), let p = snap.profile(f) {
            do { try ProfileAdmin.edit(p, name: p.displayName, color: p.colorKey, makeApp: true, scanner: scanner) { print("..", $0) }; print("made app") }
            catch { print("error:", error.localizedDescription) }
            return true
        }
        let rel = RelativeDateTimeFormatter()
        if args.contains("--ax") { print("accessibility access: \(QuitHelper.hasAccess)") }
        if args.contains("--status") {
            print("scan took \(String(format: "%.3f", Date().timeIntervalSince(t0)))s  cli=\(snap.cliEmail ?? "-")")
            let t1 = Date(); _ = scanner.scan()
            print("warm rescan took \(String(format: "%.3f", Date().timeIntervalSince(t1)))s")
            for p in snap.profiles {
                let u = p.usage
                print("\(p.displayName.padding(toLength: 9, withPad: " ", startingAt: 0)) \(p.running ? "RUN" : "   ") \((p.email ?? "?").padding(toLength: 34, withPad: " ", startingAt: 0)) \((p.plan ?? "?").padding(toLength: 8, withPad: " ", startingAt: 0)) 5h:\(u?.fiveHour.map { "\(Int($0.leftPct))%" } ?? "-") wk:\(u?.week.map { "\(Int($0.leftPct))%\($0.probablyReset ? "*" : "")" } ?? "-") own:\(p.ownChats.count) behind:\(snap.behind(p))")
            }
            if let n = snap.newestChat { print("newest: \(n.title) in \(n.profileFolder) \(rel.localizedString(for: n.lastActivity, relativeTo: Date()))") }
            print("suggest: \(snap.suggestion?.displayName ?? "-")")
        }
        if args.contains("--usage") {
            let store = UsageService.refresh(profiles: snap.profiles, settingsDir: scanner.settingsDir, force: true, allowPrompt: false)
            for (f, u) in store.sorted(by: { $0.key < $1.key }) {
                print("\(f): 5h \(u.fiveHour.map { "\(Int($0))%" } ?? "-") week \(u.week.map { "\(Int($0))%" } ?? "-") fable \(u.fable.map { "\(Int($0))%" } ?? "-") plan \(u.plan ?? "-") problem: \(u.problem ?? "none")")
            }
        }
        if base != nil, let name = val("--create") {
            do { print("created", try ProfileAdmin.create(name: name, color: "blue", makeApp: true, copyServers: true, open: false, scanner: scanner) { print("..", $0) }) }
            catch { print("error:", error.localizedDescription) }
        }
        if base != nil, args.contains("--take-over") {
            do { print("took over:", try ProfileAdmin.takeOverFromGraft(scanner: scanner) { print("..", $0) }) }
            catch { print("error:", error.localizedDescription) }
        }
        if args.contains("--links") {
            for p in snap.profiles {
                print("\(p.folder): \(Relocator.brokenLinks(p, base: scanner.base)) chats point into other profiles")
            }
        }
        if base != nil, args.contains("--repair-all") {
            do { print("repaired:", try ProfileAdmin.repairAll(scanner: scanner) { print("..", $0) }) }
            catch { print("error:", error.localizedDescription) }
        }
        if base != nil, let f = val("--repair"), let p = snap.profile(f) {
            do { print("repaired \(try Relocator.repair(p, base: scanner.base, projectsDir: scanner.projectsDir)) chats in \(f)") }
            catch { print("error:", error.localizedDescription) }
        }
        if args.contains("--live-fix"), args.contains("--confirm-live"), base == nil {
            let log = scanner.settingsDir.appendingPathComponent("last-run.log")
            var lines: [String] = []
            func note(_ s: String) {
                lines.append("\(Date()) \(s)")
                try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
            }
            if let d = val("--delay").flatMap(Double.init) { note("waiting \(d)s"); Thread.sleep(forTimeInterval: d) }
            do {
                let fixed = try ProfileAdmin.repairAll(scanner: scanner) { note($0) }
                note("repaired: \(fixed)")
                if !fixed.isEmpty {
                    HistoryStore.append(HistoryEntry(date: Date(), kind: "repair", target: Fmt.list(fixed.keys.sorted()), source: "", added: fixed.values.reduce(0, +), updated: 0, notes: 0, quit: [], backup: nil, ok: true, message: ""))
                }
                if let f = val("--delete"), let p = scanner.scan().profile(f) {
                    let t = try ProfileAdmin.delete(p, scanner: scanner) { note($0) }
                    note("trashed: \(t.map(\.path))")
                    HistoryStore.append(HistoryEntry(date: Date(), kind: "delete", target: p.displayName, source: "", added: 0, updated: 0, notes: 0, quit: [], backup: nil, ok: true, message: "Moved \(Fmt.list(t.map(\.lastPathComponent))) to the Trash"))
                }
                for o in scanner.scan().profiles { note("\(o.folder): \(Relocator.brokenLinks(o, base: scanner.base)) chats point into other profiles") }
                note("done")
            } catch { note("error: \(error.localizedDescription)") }
        }
        if let f = val("--impact"), let p = snap.profile(f) {
            let i = ProfileAdmin.impact(of: p, in: snap)
            print("impact \(f): only here \(i.onlyHere.count)  newest here \(i.newestHere.count)  files inside \(i.filesInside.map(\.title))  linked from \(i.linkedFrom.map { "\($0.profile.folder):\($0.chats)" })  trash \(i.trashItems.map(\.lastPathComponent))")
        }
        if base != nil, let f = val("--rename"), let p = snap.profile(f), let newName = val("--to") {
            if let e = ProfileAdmin.validate(newName, for: p, in: snap, scanner: scanner) { print("invalid:", e) }
            else {
                do { try ProfileAdmin.edit(p, name: newName, color: p.colorKey, makeApp: false, scanner: scanner) { print("..", $0) }; print("renamed") }
                catch { print("error:", error.localizedDescription) }
            }
        }
        if base != nil, let f = val("--delete"), let p = snap.profile(f) {
            do { let t = try ProfileAdmin.delete(p, scanner: scanner) { print("..", $0) }; print("trashed:", t.map(\.path)) }
            catch { print("error:", error.localizedDescription) }
        }
        if let target = val("--plan") ?? val("--sync") {
            let mode: SourceMode = val("--from").map { .profile($0) } ?? .newestEverywhere
            do {
                if args.contains("--sync") {
                    guard base != nil else { print("--sync needs --base <copy of Application Support>"); return true }
                    let r = try SyncEngine.run(scanner: scanner, target: target, mode: mode,
                                               options: SyncOptions(quitOthers: false, openAfter: false)) { s, m in print("..", s, m) }
                    print("synced: added \(r.plan.added) updated \(r.plan.updated) notes \(r.plan.notes.count) backup \(r.backup?.lastPathComponent ?? "-")")
                    let after = Scanner(base: base).scan()
                    if let t = after.profile(target) { print("after: own \(t.ownChats.count) behind \(after.behind(t))") }
                } else {
                    let p = try SyncEngine.plan(snap, target: target, mode: mode)
                    print("plan into \(p.targetName): add \(p.added) update \(p.updated) current \(p.alreadyCurrent) notes \(p.notes.count) total after \(p.totalAfter)")
                    print("quit: \(p.toQuit.map(\.displayName))  recently active: \(p.recentlyActive.map(\.title))")
                }
            } catch { print("error:", error.localizedDescription) }
        }
        return true
    }
}
