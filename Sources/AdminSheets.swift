import SwiftUI

// MARK: Colour swatches

struct ColorSwatches: View {
    @Binding var selection: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ColorPreset.allCases) { c in
                Button { withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.4)) { selection = c.rawValue } } label: {
                    Circle()
                        .fill(profileColor(c.rawValue).gradient)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if selection == c.rawValue {
                                Circle().strokeBorder(.white, lineWidth: 2).padding(3)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .scaleEffect(selection == c.rawValue ? 1.12 : 1)
                }
                .buttonStyle(PressStyle())
                .help(c.label)
                .accessibilityLabel(c.label)
            }
        }
    }
}

struct IconPreview: View {
    let color: String
    let badge: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { RoundedRectangle(cornerRadius: 14).fill(.quaternary) }
        }
        .frame(width: 64, height: 64)
        .task(id: color + badge) {
            let c = color, b = badge
            let img = ShortcutMaker.renderIcon(color: c, badge: b, size: 256)
            withAnimation(.smooth(duration: 0.25)) { image = img }
        }
    }
}

// MARK: Edit (name, colour, app)

struct RenameSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    let folder: String
    @State private var name = ""
    @State private var color = "claude"
    @State private var makeApp = true
    @State private var step: String?
    @State private var error: String?
    @FocusState private var focused: Bool

    var p: Profile? { m.snap?.profile(folder) }

    var problem: String? {
        guard let p, let snap = m.snap else { return "Couldn't find that profile." }
        return ProfileAdmin.validate(name, for: p, in: snap, scanner: m.scanner)
    }

    var unchanged: Bool {
        guard let p else { return true }
        return name.trimmingCharacters(in: .whitespaces) == p.displayName && color == (p.colorKey ?? "claude")
            && !(makeApp && p.shortcutApp == nil) && !p.appByGraft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let p {
                HStack(spacing: 16) {
                    IconPreview(color: color, badge: ProfileAdmin.badge(for: name.isEmpty ? p.displayName : name, folder: p.folder))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Edit \(p.displayName)").font(.title2.weight(.semibold))
                        Text(p.email ?? p.folder).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.callout.weight(.medium))
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { if problem == nil && !unchanged { start(p) } }
                    Text(problem ?? " ").font(.callout).foregroundStyle(.red)
                        .opacity(problem != nil && !name.isEmpty ? 1 : 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Colour").font(.callout.weight(.medium))
                    ColorSwatches(selection: $color)
                }
                if p.shortcutApp == nil && !p.isMain {
                    Toggle("Add \(name.isEmpty ? "it" : name) to Applications", isOn: $makeApp).toggleStyle(.checkbox)
                } else if p.appByGraft {
                    Text("Its app in Applications still runs through Claude Graft. Saving rebuilds it as a Relaycat app.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Chats, sign-in and the \(p.folder) folder don't change.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    if let step { ProgressView().controlSize(.small); Text(step).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(step != nil)
                    Button("Save") { start(p) }
                        .keyboardShortcut(.defaultAction)
                        .primaryAction()
                        .disabled(problem != nil || unchanged || step != nil)
                }
            }
        }
        .padding(DS.xxl)
        .frame(width: DS.sheetWidth)
        .onAppear {
            name = p?.displayName ?? ""
            color = p?.colorKey ?? "claude"
            makeApp = p?.isMain == true ? false : true
            focused = true
        }
    }

    func start(_ p: Profile) {
        if m.demoBlocked() { dismiss(); return }
        let scanner = m.scanner, newName = name.trimmingCharacters(in: .whitespacesAndNewlines), old = p.displayName
        let c = color, app = makeApp
        step = "Saving…"
        m.working = true
        Task.detached {
            do {
                try ProfileAdmin.edit(p, name: newName, color: c, makeApp: app, scanner: scanner) { s in Task { @MainActor in step = s } }
                await MainActor.run {
                    m.working = false
                    if newName != old {
                        m.addHistory(HistoryEntry(date: Date(), kind: "rename", target: newName, source: old, added: 0, updated: 0, notes: 0, quit: [], backup: nil, ok: true, message: ""))
                    }
                    m.show(newName != old ? "\(old) is now \(newName)" : "Saved \(newName)")
                    Haptic.done()
                    m.refresh()
                    dismiss()
                }
            } catch {
                await MainActor.run { m.working = false; step = nil; self.error = error.localizedDescription; m.refresh() }
            }
        }
    }
}

// MARK: New profile

struct NewProfileSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var color = "blue"
    @State private var makeApp = true
    @State private var copyServers = true
    @State private var openNow = true
    @State private var step: String?
    @State private var error: String?
    @FocusState private var focused: Bool

    var folder: String { ProfileAdmin.nextFolder(scanner: m.scanner) }
    var problem: String? {
        guard let snap = m.snap else { return nil }
        return ProfileAdmin.validate(name, for: nil, in: snap, scanner: m.scanner)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                IconPreview(color: color, badge: ProfileAdmin.badge(for: name.isEmpty ? "C" : name, folder: folder))
                VStack(alignment: .leading, spacing: 4) {
                    Text("New profile").font(.title2.weight(.semibold))
                    Text("A separate Claude with its own sign-in, so you can use another account.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.callout.weight(.medium))
                TextField("Claude \(folder.split(separator: "-").last ?? "")", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if problem == nil { start() } }
                Text(problem ?? " ").font(.callout).foregroundStyle(.red).opacity(problem != nil && !name.isEmpty ? 1 : 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Colour").font(.callout.weight(.medium))
                ColorSwatches(selection: $color)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Add it to Applications", isOn: $makeApp)
                Toggle("Copy MCP servers from Claude", isOn: $copyServers)
                Toggle("Open it now to sign in", isOn: $openNow)
            }
            .toggleStyle(.checkbox)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if let step { ProgressView().controlSize(.small); Text(step).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(step != nil)
                Button("Create") { start() }
                    .keyboardShortcut(.defaultAction)
                    .primaryAction()
                    .disabled((problem != nil && !name.isEmpty) || step != nil)
            }
        }
        .padding(DS.xxl)
        .frame(width: DS.sheetWidth)
        .onAppear { focused = true }
    }

    func start() {
        if m.demoBlocked() { dismiss(); return }
        let scanner = m.scanner
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Claude \(folder.split(separator: "-").last ?? "")" : name
        let c = color, app = makeApp, servers = copyServers, open = openNow
        step = "Creating…"
        m.working = true
        Task.detached {
            do {
                let f = try ProfileAdmin.create(name: finalName, color: c, makeApp: app, copyServers: servers, open: open, scanner: scanner) { s in
                    Task { @MainActor in step = s }
                }
                await MainActor.run {
                    m.working = false
                    m.addHistory(HistoryEntry(date: Date(), kind: "create", target: finalName, source: f, added: 0, updated: 0, notes: 0, quit: [], backup: nil, ok: true, message: ""))
                    m.show(open ? "\(finalName) is opening. Sign in there." : "Created \(finalName)")
                    Haptic.done()
                    m.refresh()
                    m.selected = f
                    dismiss()
                }
            } catch {
                await MainActor.run { m.working = false; step = nil; self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: Move off Claude Graft

struct TakeOverSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var step: String?
    @State private var done: [String]?
    @State private var error: String?

    var graftApps: [Profile] { m.snap?.profiles.filter(\.appByGraft) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let done {
                Label { Text("Relaycat runs your profiles now").font(.title2.weight(.semibold)) } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).symbolEffect(.bounce, value: done.count)
                }
                Text(done.isEmpty ? "Claude Graft is closed." : "Rebuilt \(Fmt.list(done)). Claude Graft is closed. You can drag it from Applications to the Trash whenever you like.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).primaryAction() }
            } else {
                Text("Stop using Claude Graft?").font(.title2.weight(.semibold))
                VStack(alignment: .leading, spacing: 10) {
                    bullet("app.badge", "Your profile apps get rebuilt by Relaycat", graftApps.isEmpty ? "None left to rebuild." : "\(Fmt.list(graftApps.map(\.displayName))) keep their names and colours.")
                    bullet("arrow.triangle.2.circlepath", "Chats stop copying themselves around", "Claude Graft's apps copy chats between profiles each time they open. Relaycat copies only when you switch.")
                    bullet("gauge.with.dots.needle.33percent", "Limits come straight from Anthropic", "Turn on live limits in Settings. Until then, Relaycat shows what the Claude app recorded.")
                    bullet("xmark.circle", "Claude Graft closes", "Nothing is deleted. Your profiles, chats and sign-ins stay as they are.")
                }
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    if let step { ProgressView().controlSize(.small); Text(step).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Not now") { dismiss() }.keyboardShortcut(.cancelAction).disabled(step != nil)
                    Button("Stop using Claude Graft") { start() }.keyboardShortcut(.defaultAction).primaryAction().disabled(step != nil)
                }
            }
        }
        .padding(DS.xxl)
        .frame(width: DS.sheetWidth)
    }

    func bullet(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func start() {
        if m.demoBlocked() { dismiss(); return }
        let scanner = m.scanner
        step = "Starting…"
        m.working = true
        Task.detached {
            do {
                let names = try ProfileAdmin.takeOverFromGraft(scanner: scanner) { s in Task { @MainActor in step = s } }
                await MainActor.run {
                    m.working = false
                    withAnimation(.smooth) { done = names }
                    Haptic.done()
                    m.addHistory(HistoryEntry(date: Date(), kind: "takeover", target: "Relaycat", source: "Claude Graft", added: names.count, updated: 0, notes: 0, quit: ["Claude Graft"], backup: nil, ok: true, message: names.isEmpty ? "" : "Rebuilt \(Fmt.list(names))"))
                    m.refresh()
                }
            } catch {
                await MainActor.run { m.working = false; step = nil; self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: Delete

struct DeleteSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    let folder: String
    @State private var impact: ProfileAdmin.DeleteImpact?
    @State private var size: Int64?
    @State private var confirm = ""
    @State private var step: String?
    @State private var done: [URL]?
    @State private var error: String?
    @State private var keptName = ""
    @State private var profile: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let done {
                HStack(spacing: 12) {
                    Image(systemName: "trash.circle.fill").font(.system(size: 36)).foregroundStyle(.secondary)
                        .symbolEffect(.bounce, value: done.count)
                    Text("\(keptName) is in the Trash").font(.title2.weight(.semibold))
                }
                Text("Changed your mind? Drag \(Fmt.list(done.map(\.lastPathComponent))) out of the Trash and it all comes back. Your other profiles weren't touched.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).primaryAction() }
            } else if let p = profile {
                review(p)
            } else {
                Text("Couldn't find that profile.")
                HStack { Spacer(); Button("Close") { dismiss() } }
            }
        }
        .padding(DS.xxl)
        .frame(width: DS.sheetWidth)
        .onAppear(perform: load)
    }

    @ViewBuilder func review(_ p: Profile) -> some View {
        HStack(spacing: 12) {
            Avatar(p: p, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Delete \(p.displayName)?").font(.title2.weight(.semibold))
                Text([p.email, p.plan].compactMap { $0 }.joined(separator: ", ")).foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            point("trash", "Goes to the Trash",
                  "Its sign-in, chat list, notes, settings and backups\(size.map { " (" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + ")" } ?? "")\(p.shortcutApp.map { ", plus \($0.deletingPathExtension().lastPathComponent) in Applications" } ?? "").")
            point("checkmark.shield", "Stays", "Your other profiles, and your projects and chat history on disk.")
            if p.running { point("xmark.circle", "Closes first", "\(p.displayName) is open right now.") }
        }

        if let i = impact {
            if !i.linkedFrom.isEmpty {
                point("arrow.right.doc.on.clipboard", "Moves out first",
                      "\(Fmt.list(i.linkedFrom.map { "\(Fmt.plural($0.chats, "chat")) in \($0.profile.displayName)" })) use files stored in \(p.displayName). Those files are copied over before anything is deleted\(i.linkedFrom.contains { $0.profile.running } ? ", so \(Fmt.list(i.linkedFrom.filter { $0.profile.running }.map(\.profile.displayName))) closes for a moment and reopens" : "").")
            }
            if !i.filesInside.isEmpty {
                warning("\(Fmt.plural(i.filesInside.count, "chat")) keep \(i.filesInside.count == 1 ? "its" : "their") files inside \(p.displayName) because \(i.filesInside.count == 1 ? "it was" : "they were") started without a project folder. Those files go to the Trash too.",
                        items: i.filesInside.map(\.title))
            }
            if !(i.onlyHere.isEmpty && i.newestHere.isEmpty) {
                VStack(alignment: .leading, spacing: 8) {
                    warning(lossText(i), items: (i.onlyHere + i.newestHere).map(\.title))
                    if let keep = keepTarget(p) {
                        Button("Copy them to \(keep.displayName) first") {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { m.requestSwitch(keep.folder, mode: .profile(p.folder)) }
                        }
                        .secondaryAction()
                        .padding(.leading, 26)
                    }
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Type **\(p.displayName)** to confirm").font(.callout)
            TextField(p.displayName, text: $confirm).textFieldStyle(.roundedBorder)
        }

        if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

        HStack {
            if let step { ProgressView().controlSize(.small); Text(step).foregroundStyle(.secondary) }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(step != nil)
            Button("Move to Trash", role: .destructive) { start(p) }
                .keyboardShortcut(.defaultAction)
                .primaryAction()
                .tint(.red)
                .disabled(confirm.trimmingCharacters(in: .whitespaces) != p.displayName || step != nil)
        }
    }

    func point(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(body).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func warning(_ text: String, items: [String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(items.prefix(4), id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if items.count > 4 { Text("and \(items.count - 4) more").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    func lossText(_ i: ProfileAdmin.DeleteImpact) -> String {
        var parts: [String] = []
        if !i.onlyHere.isEmpty { parts.append("\(Fmt.plural(i.onlyHere.count, "chat")) \(i.onlyHere.count == 1 ? "is" : "are") only in this profile") }
        if !i.newestHere.isEmpty { parts.append("\(Fmt.plural(i.newestHere.count, "chat")) \(i.newestHere.count == 1 ? "has its" : "have their") latest messages only here") }
        return Fmt.list(parts) + ". They'd drop off your chat list."
    }

    func keepTarget(_ p: Profile) -> Profile? {
        guard let snap = m.snap else { return nil }
        let others = snap.profiles.filter { $0.folder != p.folder && $0.targetDir != nil }
        if let s = snap.suggestion, s.folder != p.folder, others.contains(where: { $0.folder == s.folder }) { return s }
        return others.first { $0.running } ?? others.first
    }

    func load() {
        guard let p = m.snap?.profile(folder), let snap = m.snap else { return }
        profile = p
        keptName = p.displayName
        impact = ProfileAdmin.impact(of: p, in: snap)
        let path = p.path
        Task.detached {
            let s = ProfileAdmin.sizeOnDisk(path)
            await MainActor.run { withAnimation { size = s } }
        }
    }

    func start(_ p: Profile) {
        if m.demoBlocked() { dismiss(); return }
        let scanner = m.scanner, name = p.displayName
        step = "Starting…"
        m.working = true
        Task.detached {
            do {
                let trashed = try ProfileAdmin.delete(p, scanner: scanner) { s in Task { @MainActor in step = s } }
                await MainActor.run {
                    m.working = false
                    if m.selected == p.folder { m.selected = nil }
                    if m.sidebar == .profile(p.folder) { m.sidebar = .page(.profiles) }
                    withAnimation(.smooth) { done = trashed }
                    Haptic.done()
                    m.addHistory(HistoryEntry(date: Date(), kind: "delete", target: name, source: "", added: 0, updated: 0, notes: 0, quit: p.running ? [name] : [], backup: nil, ok: true, message: "Moved \(Fmt.list(trashed.map(\.lastPathComponent))) to the Trash"))
                    m.refresh()
                }
            } catch {
                await MainActor.run { m.working = false; step = nil; self.error = error.localizedDescription; m.refresh() }
            }
        }
    }
}

// MARK: Restore

struct RestoreSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.dismiss) var dismiss
    let request: RestoreRequest
    @State private var openAfter = true
    @State private var step: String?
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        let b = request.backup
        let name = m.snap?.profile(b.profileFolder)?.displayName ?? b.profileFolder
        VStack(alignment: .leading, spacing: 16) {
            if let result {
                HStack(spacing: 10) {
                    Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 30)).foregroundStyle(failed ? .red : .green)
                        .symbolEffect(.bounce, value: result)
                    Text(failed ? "Couldn't restore" : "\(name) is restored").font(.title2.weight(.semibold))
                }
                Text(result).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).primaryAction() }
            } else {
                Text("Restore \(name) to \(Fmt.when(b.date))?").font(.title2.weight(.semibold))
                Text("\(name)'s chat list goes back to the \(Fmt.plural(b.chatCount, "chat")) it had then. What it has now is backed up first, so you can come back to it. \(name) closes if it's open. Other profiles aren't touched.")
                    .fixedSize(horizontal: false, vertical: true)
                if let l = b.label { Text(l).font(.callout).foregroundStyle(.secondary) }
                Toggle("Open \(name) afterwards", isOn: $openAfter).toggleStyle(.checkbox)
                HStack {
                    if let step { ProgressView().controlSize(.small); Text(step).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(step != nil)
                    Button("Restore") { start() }.keyboardShortcut(.defaultAction).primaryAction().disabled(step != nil)
                }
            }
        }
        .padding(DS.xxl)
        .frame(width: DS.sheetWidth)
        .animation(.smooth, value: result)
    }

    func start() {
        if m.demoBlocked() { dismiss(); return }
        let scanner = m.scanner, b = request.backup, open = openAfter
        let name = m.snap?.profile(b.profileFolder)?.displayName ?? b.profileFolder
        m.working = true
        step = "Starting…"
        Task.detached {
            do {
                let safety = try SyncEngine.restore(scanner: scanner, backup: b, openAfter: open) { s in
                    Task { @MainActor in step = s }
                }
                await MainActor.run {
                    result = "\(name) has its \(Fmt.plural(b.chatCount, "chat")) from that backup again. What it had a moment ago is saved in Backups."
                    Haptic.done()
                    m.working = false
                    m.addHistory(HistoryEntry(date: Date(), kind: "restore", target: name, source: Fmt.when(b.date), added: b.chatCount, updated: 0, notes: 0, quit: [], backup: safety.path, ok: true, message: ""))
                    m.refresh()
                }
            } catch {
                await MainActor.run {
                    failed = true
                    result = error.localizedDescription
                    m.working = false
                    m.refresh()
                }
            }
        }
    }
}
