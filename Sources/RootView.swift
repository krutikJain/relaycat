import SwiftUI

struct RootView: View {
    @EnvironmentObject var m: AppModel
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .frame(minWidth: m.showInspector && m.page == .profiles ? 1000 : 780, minHeight: 540)
        .overlay { MochiStroll() }
        .background(WindowOpener())
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(item: $m.request) { SwitchSheet(request: $0) }
        .sheet(item: $m.restore) { RestoreSheet(request: $0) }
        .sheet(item: $m.renaming) { RenameSheet(folder: $0.folder) }
        .sheet(item: $m.deleting) { DeleteSheet(folder: $0.folder) }
        .sheet(isPresented: $m.creating) { NewProfileSheet() }
        .sheet(isPresented: $m.takingOver) { TakeOverSheet() }
        .onChange(of: m.sidebar) { _, new in
            if case .profile(let f) = new { m.select(f) }
        }
    }

    @ViewBuilder var detail: some View {
        if let snap = m.snap {
            Group {
                switch m.page {
                case .profiles:
                    HStack(spacing: 0) {
                        ProfilesPage(snap: snap)
                            .frame(minWidth: 380, maxWidth: .infinity)
                        if m.showInspector && !snap.profiles.isEmpty {
                            Divider()
                            Group {
                                if let sel = m.selected, let p = snap.profile(sel) {
                                    InspectorView(p: p, snap: snap)
                                } else {
                                    ContentUnavailableView("Pick a profile", systemImage: "person.crop.circle",
                                                           description: Text("Its limits, chats and settings show up here."))
                                }
                            }
                            .frame(width: 320)
                            .frame(maxHeight: .infinity)
                            .background(.background)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .clipped()
                    .animation(.smooth(duration: 0.3), value: m.showInspector)
                case .chats: ChatsPage(snap: snap)
                case .backups: BackupsPage(snap: snap)
                case .activity: ActivityPage()
                }
            }
            .navigationTitle(m.page.title)
            .toolbar { toolbar }
        } else {
            ProgressView("Reading your Claude profiles…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { m.creating = true } label: { Label("New profile", systemImage: "plus") }
                .help("Add another Claude with its own sign-in")
                .keyboardShortcut("n")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { m.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Check again now. Relaycat also checks every few seconds.")
        }
        if m.page == .profiles {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.smooth) { m.showInspector.toggle() }
                } label: { Label("Details", systemImage: "sidebar.trailing") }
                .help(m.showInspector ? "Hide details" : "Show details")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var m: AppModel

    var body: some View {
        List(selection: $m.sidebar) {
            Section {
                ForEach(Page.allCases) { p in
                    Label(p.title, systemImage: p.icon)
                        .badge(badge(p))
                        .tag(SidebarItem.page(p))
                }
            }
            if let snap = m.snap, !snap.profiles.isEmpty {
                Section("Your profiles") {
                    ForEach(snap.profiles) { p in
                        HStack(spacing: 8) {
                            Avatar(p: p, size: 20)
                            Text(p.displayName).lineLimit(1)
                            Spacer(minLength: 4)
                            if let w = p.usage?.week {
                                Text("\(Int(w.leftPct))%")
                                    .font(.caption.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(w.leftPct < 15 ? Color.red : Color.secondary)
                                    .contentTransition(.numericText(value: w.leftPct))
                                    .help("Left this week")
                            }
                        }
                        .tag(SidebarItem.profile(p.folder))
                        .contextMenu { ProfileActions(p: p, snap: snap) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !m.hasAccess && m.quitPolicy == .quitAnyway && (m.page != .profiles || m.hideAccessNotice) {
                AccessHint(compact: true)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    func badge(_ p: Page) -> Int {
        guard p == .chats, let snap = m.snap else { return 0 }
        let signedIn = snap.profiles.filter { $0.targetDir != nil }
        return snap.newest.values.filter { c in
            !c.archived && signedIn.contains { p in !(p.ownChats[c.id].map { $0.lastActivity >= c.lastActivity } ?? false) }
        }.count
    }
}

struct AccessHint: View {
    @EnvironmentObject var m: AppModel
    var compact = false

    var body: some View {
        Notice(icon: "hand.raised.fill", tint: .orange, title: "Answer “Quit anyway?”",
               message: "Allow Accessibility so Relaycat can close Claude cleanly.") {
            Button("Allow…") { m.askForAccess() }.secondaryAction().controlSize(.small)
            Button("Fix it") { m.resetAccess() }.buttonStyle(.link).font(.caption)
                .help("Already allowed but still showing? Turn it on again for this build.")
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var m: AppModel
    var body: some View {
        if let t = m.toast {
            Text(t)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .modifier(ToastBackground())
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { withAnimation(.smooth) { m.toast = nil } }
        }
    }
}

struct ToastBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
        #else
        content.background(.regularMaterial, in: Capsule())
        #endif
    }
}

// Gives AppLifecycle a way to bring the main window back, even when the menu bar icon is hidden.
private struct WindowOpener: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { AppLifecycle.openMainWindow = { openWindow(id: "main") } }
    }
}
