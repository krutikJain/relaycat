import SwiftUI

// MARK: Shared pieces

struct Stat: View {
    let value: String
    let label: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SummaryStrip<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .top, spacing: DS.l) { content }
            .card(padding: DS.m + 2)
            .padding(.horizontal, DS.page).padding(.top, DS.l)
    }
}

// MARK: Chats: every chat, where its newest copy is, and who is missing it

struct ChatRow: Identifiable {
    var id: String { chat.id }
    var chat: ChatRecord
    var title: String { chat.title }
    var project: String { chat.project }
    var last: Date { chat.lastActivity }
    var holder: String
    var missing: Int
}

struct ChatsPage: View {
    @EnvironmentObject var m: AppModel
    let snap: Snapshot
    @State private var query = ""
    @State private var showArchived = false
    @State private var onlyMissing = false
    @State private var sort = [KeyPathComparator(\ChatRow.last, order: .reverse)]
    @State private var rows: [ChatRow] = []
    @State private var stats = (total: 0, missing: 0, projects: 0)

    var body: some View {
        VStack(spacing: 0) {
            SummaryStrip {
                Stat(value: "\(stats.total)", label: "chats across your profiles")
                Stat(value: "\(stats.missing)", label: "missing from some profile", tint: stats.missing > 0 ? .orange : .primary)
                Stat(value: "\(stats.projects)", label: "projects")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.l) { filters; Spacer(minLength: DS.l); legend }
                HStack(spacing: DS.l) { filters; Spacer(minLength: 0) }
            }
            .padding(.horizontal, DS.page).padding(.vertical, DS.m)
            Divider()
            if snap.newest.isEmpty {
                BigEmptyState(symbol: "bubble.left.and.bubble.right", title: "No chats yet",
                              message: "Chats you start in Claude's Code tab show up here, with which profile has the newest copy and which ones are missing it.") {
                    if snap.profiles.isEmpty { EmptyView() } else { Button("Open Claude") { m.openClaude() }.secondaryAction() }
                }
            } else if rows.isEmpty {
                ContentUnavailableView(onlyMissing ? "Every profile has every chat" : "No chats match",
                                       systemImage: onlyMissing ? "checkmark.circle" : "magnifyingglass",
                                       description: Text(onlyMissing ? "Nothing to bring over right now." : "Try a different search."))
                    .transition(.opacity)
            } else {
                Table(rows, sortOrder: $sort) {
                    TableColumn("Chat", value: \.title) { r in
                        HStack(spacing: 6) {
                            if r.chat.parentId != nil {
                                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                                    .help("Started from another chat")
                            }
                            Text(r.title).lineLimit(1)
                            if r.chat.archived { Text("Archived").font(.caption).foregroundStyle(.tertiary) }
                        }
                    }
                    .width(min: 130, ideal: 340)
                    TableColumn("Project", value: \.project) { r in Text(r.project).foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 52, ideal: 120)
                    TableColumn("Last used", value: \.last) { r in Text(Fmt.agoShort(r.last)).foregroundStyle(.secondary).lineLimit(1) }
                        .width(min: 70, ideal: 110)
                    TableColumn("Newest in", value: \.holder) { r in
                        HStack(spacing: 6) {
                            if let p = snap.profile(r.chat.profileFolder) { Avatar(p: p, size: 14) }
                            Text(r.holder).lineLimit(1)
                        }
                    }
                    .width(min: 62, ideal: 100)
                    TableColumn("Copies") { r in Copies(chat: r.chat, snap: snap) }
                        .width(min: 72, ideal: 130)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let c = snap.newest[id] {
                        Button("Copy title") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.title, forType: .string)
                            m.show("Copied “\(c.title)”")
                        }
                        Button("Show chat file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.path]) }
                        if let cwd = c.cwd, FileManager.default.fileExists(atPath: cwd) {
                            Button("Open project folder") { NSWorkspace.shared.open(URL(fileURLWithPath: cwd)) }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: rows.isEmpty)
        .searchable(text: $query, placement: .toolbar, prompt: "Search chats or projects")
        .onAppear(perform: rebuild)
        .onChange(of: snap.signature) { _, _ in rebuild() }
        .onChange(of: query) { _, _ in rebuild() }
        .onChange(of: showArchived) { _, _ in withAnimation(.smooth) { rebuild() } }
        .onChange(of: onlyMissing) { _, _ in withAnimation(.smooth) { rebuild() } }
        .onChange(of: sort) { _, _ in rows.sort(using: sort) }
    }

    var filters: some View {
        HStack(spacing: DS.l) {
            Picker("Show", selection: $onlyMissing) {
                Text("All chats").tag(false)
                Text("Missing somewhere").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("Archived", isOn: $showArchived).toggleStyle(.checkbox).fixedSize()
                .help("Include archived chats")
        }
    }

    var legend: some View {
        HStack(spacing: 12) {
            legendItem(AnyView(Circle().fill(Color.secondary)), "Up to date")
            legendItem(AnyView(Circle().strokeBorder(Color.secondary, lineWidth: 1.5)), "Older copy")
            legendItem(AnyView(Circle().fill(Color.primary.opacity(0.1))), "Missing")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    func legendItem(_ dot: AnyView, _ text: String) -> some View {
        HStack(spacing: 5) { dot.frame(width: 9, height: 9); Text(text) }
    }

    func rebuild() {
        let signedIn = snap.profiles.filter { $0.targetDir != nil }
        var out: [ChatRow] = []
        var missingAll = 0
        var projects = Set<String>()
        for c in snap.newest.values {
            let missing = signedIn.filter { p in !(p.ownChats[c.id].map { $0.lastActivity >= c.lastActivity } ?? false) }.count
            if !c.archived { if missing > 0 { missingAll += 1 }; if !c.project.isEmpty { projects.insert(c.project) } }
            if !showArchived && c.archived { continue }
            if !query.isEmpty && !c.title.localizedCaseInsensitiveContains(query) && !c.project.localizedCaseInsensitiveContains(query) { continue }
            if onlyMissing && missing == 0 { continue }
            out.append(ChatRow(chat: c, holder: snap.profile(c.profileFolder)?.displayName ?? c.profileFolder, missing: missing))
        }
        withAnimation(.smooth) {
            stats = (snap.newest.values.filter { !$0.archived }.count, missingAll, projects.count)
        }
        rows = out.sorted(using: sort)
    }
}

struct Copies: View {
    let chat: ChatRecord
    let snap: Snapshot

    var body: some View {
        HStack(spacing: 4) {
            ForEach(snap.profiles.filter { $0.targetDir != nil }) { p in
                let mine = p.ownChats[chat.id]
                let color = profileColor(p.colorKey)
                Group {
                    if let mine, mine.lastActivity >= chat.lastActivity {
                        Circle().fill(color.gradient)
                    } else if mine != nil {
                        Circle().strokeBorder(color, lineWidth: 1.5)
                    } else {
                        Circle().fill(Color.primary.opacity(0.08))
                    }
                }
                .frame(width: 11, height: 11)
                .help("\(p.displayName): \(mine == nil ? "doesn't have it" : (mine!.lastActivity >= chat.lastActivity ? "up to date" : "has an older copy from \(Fmt.ago(mine!.lastActivity))"))")
            }
        }
    }
}

// MARK: Backups

struct BackupsPage: View {
    @EnvironmentObject var m: AppModel
    let snap: Snapshot
    @State private var confirmCleanup = false
    @State private var confirmOne: BackupInfo?
    @State private var hovered: String?

    var all: [BackupInfo] { m.backups.values.flatMap { $0 } }
    var old: [BackupInfo] {
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        return m.backups.values.flatMap { $0.dropFirst(2).filter { $0.date < cutoff } }
    }

    var body: some View {
        if all.isEmpty {
            BigEmptyState(symbol: "clock.arrow.circlepath", mood: .napping, title: "No backups yet",
                          message: "Every time you switch, Relaycat saves the profile's chat list first. Those backups show up here, so you can undo a switch.") {
                EmptyView()
            }
        } else {
            content
        }
    }

    var content: some View {
        VStack(spacing: 0) {
            SummaryStrip {
                Stat(value: "\(all.count)", label: "backups saved")
                Stat(value: all.map(\.date).max().map { Fmt.ago($0) } ?? "never", label: "latest backup")
                HStack {
                    Spacer()
                    Button("Clean up \(old.count) old") { confirmCleanup = true }
                        .secondaryAction()
                        .disabled(old.isEmpty)
                        .help("Moves backups older than two weeks to the Trash. The newest two of each profile stay.")
                }
            }
            Text("Every switch saves the profile's chat list first. Restore puts it back exactly as it was.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 10)
            List {
                ForEach(snap.profiles) { p in
                    let list = m.backups[p.folder] ?? []
                    Section {
                        if list.isEmpty {
                            Text("None yet. One is saved the first time you switch to \(p.displayName).")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(list) { b in row(b, p) }
                    } header: {
                        HStack(spacing: 8) {
                            Avatar(p: p, size: 18)
                            Text(p.displayName).font(.headline)
                            Text(Fmt.plural(list.count, "backup")).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.inset)
            .scrollIndicators(.automatic)
            .animation(.smooth, value: all.map(\.id))
        }
        .confirmationDialog("Move \(Fmt.plural(old.count, "old backup")) to the Trash?", isPresented: $confirmCleanup) {
            Button("Move to Trash", role: .destructive) { m.trashBackups(old) }
        } message: { Text("They stay in the Trash until you empty it. The newest two of each profile are kept.") }
        .confirmationDialog("Move this backup to the Trash?", isPresented: Binding(get: { confirmOne != nil }, set: { if !$0 { confirmOne = nil } })) {
            Button("Move to Trash", role: .destructive) { if let b = confirmOne { m.trashBackups([b]) } }
        } message: { Text("It stays in the Trash until you empty it.") }
    }

    func row(_ b: BackupInfo, _ p: Profile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(profileColor(p.colorKey))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.when(b.date).prefix(1).uppercased() + Fmt.when(b.date).dropFirst())
                    .font(.body.weight(.medium))
                Text(b.label ?? "Saved by an earlier switch").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Fmt.plural(b.chatCount, "chat")).foregroundStyle(.secondary).monospacedDigit()
            Button { m.restore = RestoreRequest(backup: b) } label: { ActionLabel("Restore") }
                .secondaryAction()
                .disabled(b.chatCount == 0 || p.targetDir == nil)
            Menu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }
                Button("Move to Trash", role: .destructive) { confirmOne = b }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hovered == b.id ? 1 : 0.5)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? b.id : (hovered == b.id ? nil : hovered) }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

// MARK: Activity

struct ActivityPage: View {
    @EnvironmentObject var m: AppModel

    var groups: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        var order: [String] = []
        var map: [String: [HistoryEntry]] = [:]
        for e in m.history {
            let key: String
            if cal.isDateInToday(e.date) { key = "Today" }
            else if cal.isDateInYesterday(e.date) { key = "Yesterday" }
            else { key = e.date.formatted(.dateTime.weekday(.wide).day().month(.wide)) }
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(e)
        }
        return order.map { ($0, map[$0]!) }
    }

    var body: some View {
        if m.history.isEmpty {
            BigEmptyState(symbol: "list.bullet", title: "Nothing here yet",
                          message: "Switches, restores, renames and new profiles show up here, with what changed and when.") {
                EmptyView()
            }
        } else {
            List {
                ForEach(groups, id: \.0) { day, entries in
                    Section(day) {
                        ForEach(entries) { e in row(e) }
                    }
                }
            }
            .listStyle(.inset)
            .animation(.smooth, value: m.history.count)
        }
    }

    func row(_ e: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(e))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background((e.ok ? tint(e) : Color.red).gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title(e)).font(.body.weight(.medium))
                let d = detail(e)
                if !d.isEmpty {
                    Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(e.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    func tint(_ e: HistoryEntry) -> Color {
        switch e.kind {
        case "switch": return .accentColor
        case "restore": return .teal
        case "delete": return .gray
        case "repair": return .orange
        case "create": return .green
        case "takeover": return .indigo
        default: return .secondary
        }
    }

    func icon(_ e: HistoryEntry) -> String {
        if !e.ok { return "exclamationmark" }
        switch e.kind {
        case "switch": return "arrow.left.arrow.right"
        case "restore": return "clock.arrow.circlepath"
        case "open": return "macwindow"
        case "quit": return "xmark"
        case "rename": return "pencil"
        case "delete": return "trash"
        case "repair": return "wrench.and.screwdriver"
        case "create": return "plus"
        case "takeover": return "arrow.triangle.2.circlepath"
        default: return "circle"
        }
    }

    func title(_ e: HistoryEntry) -> String {
        if !e.ok {
            switch e.kind {
            case "switch": return "Couldn't switch to \(e.target)"
            default: return "\(e.target): didn't work"
            }
        }
        switch e.kind {
        case "switch": return "Switched to \(e.target)"
        case "restore": return "Restored \(e.target)"
        case "open": return "Opened \(e.target)"
        case "quit": return "Closed \(e.target)"
        case "rename": return "Renamed \(e.source) to \(e.target)"
        case "delete": return "Deleted \(e.target)"
        case "repair": return "Fixed chats in \(e.target)"
        case "create": return "Created \(e.target)"
        case "takeover": return "Stopped using Claude Graft"
        default: return e.target
        }
    }

    func detail(_ e: HistoryEntry) -> String {
        if !e.ok { return e.message }
        switch e.kind {
        case "switch":
            var parts: [String] = []
            if e.added + e.updated == 0 { parts.append("Chats were already up to date.") }
            else { parts.append("Brought in \(e.added) new and \(e.updated) updated \(e.added + e.updated == 1 ? "chat" : "chats").") }
            if !e.quit.isEmpty { parts.append("Closed \(Fmt.list(e.quit)).") }
            if !e.message.isEmpty && !e.message.hasPrefix("Opened") { parts.append(e.message + ".") }
            return parts.joined(separator: " ")
        case "restore": return "From \(e.source)."
        case "delete": return e.message.isEmpty ? "" : e.message + "."
        case "repair": return "\(Fmt.plural(e.added, "chat")) used files kept in other profiles. Those files were copied over, so deleting a profile no longer breaks them."
        case "create": return "Folder \(e.source). Sign in when it opens."
        case "takeover": return e.message.isEmpty ? "Claude Graft is closed." : e.message + ". Claude Graft is closed."
        default: return ""
        }
    }
}
