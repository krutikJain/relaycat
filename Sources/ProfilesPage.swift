import SwiftUI

struct ProfilesPage: View {
    @EnvironmentObject var m: AppModel
    let snap: Snapshot
    @State private var hovered: String?
    @FocusState private var focused: Bool

    var body: some View {
        if snap.profiles.isEmpty { firstRun } else { list }
    }

    @ViewBuilder var firstRun: some View {
        if !m.claudeInstalled {
            BigEmptyState(symbol: "arrow.down", title: "Install Claude to get started",
                          message: "Relaycat manages Claude for Mac profiles. Install Claude, open it once and sign in, and your profile shows up here.") {
                Button("Download Claude") { NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!) }.primaryAction()
                Button("Check again") { m.refresh() }.secondaryAction()
            }
        } else {
            BigEmptyState(symbol: "person.crop.circle.badge.plus", title: "Open Claude once",
                          message: "Claude creates its first profile the first time it opens. Sign in there, and it shows up here with its limits and chats.") {
                Button("Open Claude") { m.openClaude() }.primaryAction()
                Button("Check again") { m.refresh() }.secondaryAction()
            }
        }
    }

    var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.l) {
                notices
                VStack(spacing: DS.xs) {
                    ForEach(snap.profiles) { p in row(p) }
                }
                if snap.profiles.count == 1 { addAnother }
            }
            .padding(DS.page)
            .animation(.smooth, value: snap.profiles.map(\.folder))
        }
        .scrollIndicators(.automatic)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) {
            if let f = m.selected, snap.profile(f)?.targetDir != nil { m.requestSwitch(f) }
            return .handled
        }
        .onAppear { focused = true }
        .animation(.smooth, value: m.hasAccess)
        .animation(.smooth, value: m.hideAccessNotice)
        .animation(.smooth, value: m.hideGraftNotice)
    }

    var addAnother: some View {
        HStack(alignment: .center, spacing: DS.l) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: DS.xs) {
                Text("Add a second Claude").font(.headline)
                Text("Sign in with another account in its own window. When one runs low, switch to the other and your chats come along.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("New profile") { m.creating = true }.primaryAction()
        }
        .card()
        .padding(.top, DS.s)
        .transition(.opacity)
    }

    @ViewBuilder var notices: some View {
        if snap.profiles.contains(where: \.appByGraft) && !m.hideGraftNotice {
            Notice(icon: "arrow.triangle.2.circlepath", title: "Your profile apps still run through Claude Graft",
                   message: "They copy chats between profiles on their own each time they open. Relaycat can run them instead.",
                   onClose: { withAnimation(.smooth) { m.hideGraftNotice = true } }) {
                Button("Review…") { m.takingOver = true }.secondaryAction()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if !m.hasAccess && m.quitPolicy == .quitAnyway && !m.hideAccessNotice {
            Notice(icon: "hand.raised.fill", tint: .orange, title: "Let Relaycat answer “Quit anyway?”",
                   message: "Claude sometimes asks before it closes. With Accessibility access, Relaycat answers for you instead of closing Claude by force.",
                   onClose: { withAnimation(.smooth) { m.hideAccessNotice = true } }) {
                Button("Allow…") { m.askForAccess() }.secondaryAction()
                Button("Already allowed? Fix it") { m.resetAccess() }.buttonStyle(.link).font(.callout)
                    .help("Your switch in System Settings belongs to an older build. This removes it so you can turn it on again for this one.")
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    func row(_ p: Profile) -> some View {
        let selected = m.selected == p.folder
        return ProfileRow(p: p, snap: snap)
            .padding(.horizontal, DS.m).padding(.vertical, DS.m)
            .background(
                RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.13) : (hovered == p.folder ? Color.primary.opacity(0.045) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.rowRadius, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? p.folder : (hovered == p.folder ? nil : hovered) }
            .onTapGesture(count: 2) { if p.targetDir != nil { m.requestSwitch(p.folder) } }
            .simultaneousGesture(TapGesture().onEnded { withAnimation(.snappy(duration: 0.2)) { m.select(p.folder) }; focused = true })
            .contextMenu { ProfileActions(p: p, snap: snap) }
            .animation(.snappy(duration: 0.18), value: selected)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    func move(_ delta: Int) {
        let list = snap.profiles.map(\.folder)
        guard !list.isEmpty else { return }
        let i = m.selected.flatMap { list.firstIndex(of: $0) } ?? 0
        let next = list[max(0, min(list.count - 1, i + delta))]
        withAnimation(.snappy(duration: 0.2)) { m.select(next) }
    }
}

enum Cols {
    static let avatar: CGFloat = 36
    static let limitsMin: CGFloat = 170
    static let limitsMax: CGFloat = 240
}

struct ActionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).frame(width: 56) }
}

struct InUseLabel: View {
    var body: some View {
        Label("In use", systemImage: "checkmark")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: DS.actionWidth, height: 24)
            .help("This is the Claude you're using now")
    }
}

// MARK: Top band: what's open, the latest chat, where to go next

struct NowHeader: View {
    @EnvironmentObject var m: AppModel
    let snap: Snapshot

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column("Using now") {
                let running = snap.runningProfiles
                if running.isEmpty {
                    Text("Nothing open").font(.title3.weight(.semibold))
                    Text("Pick a profile below.").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: DS.s) {
                        ForEach(running) { Avatar(p: $0, size: 22) }
                        Text(Fmt.list(running.map(\.displayName))).font(.title3.weight(.semibold)).lineLimit(1)
                    }
                    Text(running.compactMap(\.email).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Divider().frame(height: 44)
            column("Latest chat") {
                if let n = snap.newestChat {
                    Text(n.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text("In \(snap.profile(n.profileFolder)?.displayName ?? n.profileFolder), \(Fmt.ago(n.lastActivity))")
                        .foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No chats yet").font(.title3.weight(.semibold))
                }
            }
            Divider().frame(height: 44)
            column("Most left") { next }
        }
        .fixedSize(horizontal: false, vertical: true)
        .card(padding: DS.m)
    }

    @ViewBuilder var next: some View {
        if let s = snap.suggestion {
            HStack(alignment: .center, spacing: DS.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                    ViewThatFits(in: .horizontal) {
                        Text(roomText(s))
                        Text(s.usage?.week.map { "\(Int($0.leftPct))% this week" } ?? "")
                    }
                    .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: DS.s)
                if snap.onBestProfile {
                    if let open = snap.runningProfiles.first, snap.runningProfiles.count == 1, snap.behind(open) > 0 {
                        Button("Update") { m.requestSwitch(open.folder) }
                            .secondaryAction()
                            .help("Bring \(Fmt.plural(snap.behind(open), "newer chat")) into \(open.displayName)")
                    }
                } else {
                    Button("Switch") { m.requestSwitch(s.folder) }
                        .primaryAction()
                        .help("Switch to \(s.displayName)")
                }
            }
        } else {
            Text("No limits yet").font(.title3.weight(.semibold))
            Text("They appear once Claude has run.").foregroundStyle(.secondary)
        }
    }

    func roomText(_ p: Profile) -> String {
        var parts: [String] = []
        if let w = p.usage?.week { parts.append("\(Int(w.leftPct))% of the week") }
        if let f = p.usage?.fiveHour, f.leftPct < 100 { parts.append("\(Int(f.leftPct))% of 5 hours") }
        return parts.joined(separator: ", ") + " left"
    }

    func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .padding(.horizontal, DS.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: One profile row

struct ProfileRow: View {
    @EnvironmentObject var m: AppModel
    let p: Profile
    let snap: Snapshot

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.l) {
                Avatar(p: p, size: Cols.avatar)
                identity.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                limits.frame(width: 200)
                action.frame(width: DS.actionWidth)
            }
            VStack(alignment: .leading, spacing: DS.m) {
                HStack(alignment: .top, spacing: DS.m) {
                    Avatar(p: p, size: Cols.avatar)
                    identity.frame(maxWidth: .infinity, alignment: .leading)
                    action.frame(width: DS.actionWidth)
                }
                limits.padding(.leading, Cols.avatar + DS.m)
            }
        }
    }

    var identity: some View {
        let shared = snap.sharesAccount(p)
        let isSuggestion = snap.suggestion?.folder == p.folder && !snap.onBestProfile
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DS.s) {
                Text(p.displayName).font(.headline).lineLimit(1)
                if let plan = p.plan { Text(plan).font(.caption).foregroundStyle(.secondary).fixedSize() }
                if isSuggestion { StatusTag(text: "Most left", color: .accentColor).fixedSize() }
            }
            Text(p.email ?? "Not signed in").font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: DS.s) {
                chatStatus
                if !shared.isEmpty { Text("Same login as \(Fmt.list(shared.map(\.displayName)))") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    var limits: some View {
        VStack(spacing: DS.s) {
            LimitLine(label: "5-hour", window: p.usage?.fiveHour)
            LimitLine(label: "Week", window: p.usage?.week)
        }
    }

    @ViewBuilder var chatStatus: some View {
        let behind = snap.behind(p)
        if p.targetDir == nil {
            Text("Not signed in")
        } else if behind == 0 {
            Label("All chats here", systemImage: "checkmark.circle")
        } else {
            Label("\(Fmt.plural(behind, "chat")) missing", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)
                .help("\(Fmt.plural(behind, "chat")) here \(behind == 1 ? "is" : "are") missing or older than in another profile. Switching brings them in.")
        }
    }

    @ViewBuilder var action: some View {
        let onlyThisOpen = p.running && snap.runningProfiles.count == 1
        if p.targetDir == nil {
            Button { m.open(p) } label: { ActionLabel("Sign in") }.secondaryAction()
        } else if onlyThisOpen {
            if snap.behind(p) > 0 {
                Button { m.requestSwitch(p.folder) } label: { ActionLabel("Update") }
                    .primaryAction()
                    .help("Bring the newer chats into \(p.displayName). It reopens.")
            } else {
                InUseLabel()
            }
        } else {
            Button { m.requestSwitch(p.folder) } label: { ActionLabel("Switch") }.primaryAction()
        }
    }
}

// MARK: Context menu (rows, sidebar, inspector)

struct ProfileActions: View {
    @EnvironmentObject var m: AppModel
    let p: Profile
    let snap: Snapshot

    var body: some View {
        Button("Switch to \(p.displayName)") { m.requestSwitch(p.folder) }.disabled(p.targetDir == nil)
        Menu("Copy chats into \(p.displayName) from") {
            ForEach(snap.profiles.filter { $0.folder != p.folder }) { o in
                Button(o.displayName) { m.requestSwitch(p.folder, mode: .profile(o.folder)) }
            }
        }
        .disabled(p.targetDir == nil)
        Divider()
        Button("Open next to the others") { m.open(p) }
        Button("Close \(p.displayName)") { m.quit(p) }.disabled(!p.running)
        Divider()
        if let e = p.email {
            Button("Copy email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(e, forType: .string)
                m.show("Copied \(e)")
            }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.targetDir ?? p.path]) }
        Divider()
        Button("Edit name and colour…") { m.renaming = ProfileRef(folder: p.folder) }
        Button("Delete…", role: .destructive) { m.deleting = ProfileRef(folder: p.folder) }
            .disabled(p.isMain)
    }
}
