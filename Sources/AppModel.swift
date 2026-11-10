import SwiftUI
import AppKit

enum Page: String, CaseIterable, Identifiable {
    case profiles, chats, backups, activity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profiles: return "Profiles"
        case .chats: return "Chats"
        case .backups: return "Backups"
        case .activity: return "Activity"
        }
    }
    var icon: String {
        switch self {
        case .profiles: return "person.2"
        case .chats: return "bubble.left.and.bubble.right"
        case .backups: return "clock.arrow.circlepath"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

enum SidebarItem: Hashable {
    case page(Page)
    case profile(String)
}

struct SwitchRequest: Identifiable {
    let id = UUID()
    var target: String
    var mode: SourceMode = .newestEverywhere
}

struct ProfileRef: Identifiable {
    let id = UUID()
    var folder: String
}

struct RestoreRequest: Identifiable {
    let id = UUID()
    var backup: BackupInfo
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let scanner = Scanner()
    @Published var snap: Snapshot?
    @Published var backups: [String: [BackupInfo]] = [:]
    @Published var history: [HistoryEntry] = HistoryStore.load()
    @Published var sidebar: SidebarItem? = .page(.profiles)
    @Published var selected: String?
    @Published var request: SwitchRequest?
    @Published var restore: RestoreRequest?
    @Published var renaming: ProfileRef?
    @Published var deleting: ProfileRef?
    @Published var creating = false
    @Published var takingOver = false
    @Published var checkingLimits = false
    @Published var working = false
    @Published var toast: String?
    @Published var hasAccess = QuitHelper.hasAccess

    @AppStorage("showInspector") var showInspector = true
    @AppStorage("openAfterSwitch") var openAfterSwitch = true
    @AppStorage("quitPolicy") var quitPolicyRaw = QuitPolicy.quitAnyway.rawValue
    @AppStorage("hideAccessNotice") var hideAccessNotice = false
    @AppStorage("liveLimits") var liveLimits = true
    @AppStorage("hideLimitsNotice") var hideLimitsNotice = false
    @Published var limitsNeedPermission = false
    @AppStorage("hideGraftNotice") var hideGraftNotice = false

    private var scanning = false
    private var timer: Timer?
    private var accessTimer: Timer?
    private var usageTimer: Timer?
    private var accessObserver: NSObjectProtocol?
    private var toastTask: Task<Void, Never>?

    var page: Page {
        switch sidebar {
        case .page(let p): return p
        case .profile: return .profiles
        case nil: return .profiles
        }
    }

    var quitPolicy: QuitPolicy { QuitPolicy(rawValue: quitPolicyRaw) ?? .quitAnyway }

    init() {
        refresh()
        DebugSnapshot.startIfRequested(self)
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.working else { return }
                self.refresh()
            }
        }
        accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recheckAccess() }
        }
        accessObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            for delay in [0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Task { @MainActor in self?.recheckAccess() } }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.recheckAccess() }
        }
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLimits(force: false) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refreshLimits(force: false) }
    }

    func recheckAccess() {
        let now = QuitHelper.hasAccess
        guard now != hasAccess else { return }
        withAnimation(.smooth) { hasAccess = now }
        if now { show("Done. Relaycat can now press “Quit anyway” for you.") }
    }

    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { AppLifecycle.quitCompletely() }
        }
    }

    func resetAccess() {
        Scanner.shell("/usr/bin/tccutil", ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "app.relaycat.mac"])
        _ = QuitHelper.requestAccess()
        QuitHelper.openAccessibilitySettings()
        show("Turn Relaycat on in the list that just opened.")
    }

    func refreshLimits(force: Bool, allowPrompt: Bool = false) {
        guard !isDemo, liveLimits, !checkingLimits, let snap else { return }
        checkingLimits = true
        let profiles = snap.profiles, dir = scanner.settingsDir
        Task.detached(priority: .utility) {
            _ = UsageService.refresh(profiles: profiles, settingsDir: dir, force: force, allowPrompt: allowPrompt)
            let needs = UsageService.needsPermission
            await MainActor.run {
                self.checkingLimits = false
                if self.limitsNeedPermission != needs { withAnimation(.smooth) { self.limitsNeedPermission = needs } }
                if allowPrompt && !needs { self.hideLimitsNotice = false }
                self.refresh()
            }
        }
    }

    func turnOnLiveLimits() {
        liveLimits = true
        refreshLimits(force: true, allowPrompt: true)
    }

    var isDemo: Bool { Demo.mode != nil }

    func demoBlocked() -> Bool {
        guard isDemo else { return false }
        show("Demo mode: nothing on this Mac was changed.")
        return true
    }

    func refresh() {
        if isDemo {
            let s = Demo.snapshot()
            if snap?.signature != s.signature { snap = s }
            backups = Demo.backups(s)
            history = Demo.history()
            if selected == nil { selected = s.profiles.first?.folder }
            return
        }
        guard !scanning else { return }
        scanning = true
        let scanner = self.scanner
        Task.detached(priority: .userInitiated) {
            let s = scanner.scan()
            var b: [String: [BackupInfo]] = [:]
            for p in s.profiles { b[p.folder] = scanner.backups(for: p) }
            let found = b
            await MainActor.run {
                if self.snap?.signature != s.signature { withAnimation(.smooth) { self.snap = s } }
                if self.backups.mapValues({ $0.map(\.id) }) != found.mapValues({ $0.map(\.id) }) { self.backups = found }
                if self.selected == nil || s.profile(self.selected!) == nil {
                    self.selected = s.runningProfiles.first?.folder ?? s.profiles.first?.folder
                }
                self.scanning = false
            }
        }
    }

    func select(_ folder: String) {
        selected = folder
        if !showInspector { withAnimation(.smooth) { showInspector = true } }
    }

    func requestSwitch(_ folder: String, mode: SourceMode = .newestEverywhere) {
        request = SwitchRequest(target: folder, mode: mode)
    }

    func show(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = message }
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { self.toast = nil }
        }
    }

    func addHistory(_ e: HistoryEntry) {
        HistoryStore.append(e)
        history = HistoryStore.load()
    }

    func open(_ p: Profile) {
        if demoBlocked() { return }
        SyncEngine.open(p)
        addHistory(HistoryEntry(date: Date(), kind: "open", target: p.displayName, source: "", added: 0, updated: 0, notes: 0, quit: [], backup: nil, ok: true, message: "Opened \(p.displayName) next to the others"))
        show("Opening \(p.displayName)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
    }

    func quit(_ p: Profile) {
        if demoBlocked() { return }
        let t = QuitTarget(name: p.displayName, pids: p.pids)
        working = true
        Task.detached {
            var message = ""
            var ok = true
            do {
                let r = try QuitHelper.quit([t]) { _ in }
                message = r.forced.isEmpty ? "Closed \(p.displayName)" : "Closed \(p.displayName) by force"
            } catch { ok = false; message = error.localizedDescription }
            let msg = message, success = ok
            await MainActor.run {
                self.working = false
                self.addHistory(HistoryEntry(date: Date(), kind: "quit", target: p.displayName, source: "", added: 0, updated: 0, notes: 0, quit: [p.displayName], backup: nil, ok: success, message: msg))
                self.show(msg)
                self.refresh()
            }
        }
    }

    func trashBackups(_ list: [BackupInfo]) {
        if demoBlocked() { return }
        var n = 0
        for b in list where (try? FileManager.default.trashItem(at: b.url, resultingItemURL: nil)) != nil { n += 1 }
        show("Moved \(Fmt.plural(n, "backup")) to the Trash")
        refresh()
    }

    var claudeInstalled: Bool { !Demo.claudeMissing && FileManager.default.fileExists(atPath: Scanner.claudeApp.path) }

    func openClaude() {
        if demoBlocked() { return }
        Scanner.shell("/usr/bin/open", ["-a", Scanner.claudeApp.path])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
    }

    func askForAccess() {
        if !QuitHelper.requestAccess() { QuitHelper.openAccessibilitySettings() }
    }

    var graftRunning: Bool { !ProfileAdmin.graftPids().isEmpty }
}
